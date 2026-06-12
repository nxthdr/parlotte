//! Room timeline management built on `matrix-sdk-ui`'s high-level [`Timeline`].
//!
//! The Timeline API maintains an ordered, fully-reconciled view of a room's
//! events: it merges local echoes, applies edits and redactions, aggregates
//! reactions, retries decryption when keys arrive, and exposes the result as a
//! stream of incremental diffs. We subscribe to that stream and, on every
//! batch, emit a *full snapshot* of the renderable messages to the platform
//! layer via [`TimelineListener`]. The UI just replaces its array with the
//! snapshot — no manual append/edit/redact/dedup reconciliation, which is the
//! complex, bug-prone code this module replaces.
//!
//! Only one room timeline is active at a time (the open room). Selecting a new
//! room tears the previous one down. All send operations act on the active
//! timeline so they produce local echoes that flow back through the snapshot.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use futures_util::{pin_mut, StreamExt};
use matrix_sdk::ruma::events::room::message::{
    RoomMessageEventContent, RoomMessageEventContentWithoutRelation,
};
use matrix_sdk::ruma::events::AnyMessageLikeEventContent;
use matrix_sdk::ruma::{EventId, OwnedRoomId, RoomId};
use matrix_sdk::Client;
use matrix_sdk_ui::eyeball_im::Vector;
use matrix_sdk_ui::timeline::{
    EventSendState, MsgLikeKind, ReactionStatus, RoomExt, Timeline, TimelineEventItemId,
    TimelineItem, TimelineItemContent,
};

use crate::client::{extract_body_and_formatted, extract_media_info, message_type_str};
use crate::error::{ParlotteError, Result};
use crate::message::{MessageInfo, ReactionInfo};

/// Callback trait for timeline updates. `on_timeline_update` is invoked with a
/// complete, ordered (oldest-first) snapshot of the room's renderable messages
/// every time the timeline changes.
pub trait TimelineListener: Send + Sync + 'static {
    fn on_timeline_update(&self, messages: Vec<MessageInfo>);
}

/// One running room timeline subscription. Owned entirely by the manager; its
/// `stop_flag` and task handle are unique to this generation so swapping rooms
/// can never disturb a different one.
struct TimelineGeneration {
    room_id: OwnedRoomId,
    timeline: Arc<Timeline>,
    stop_flag: Arc<AtomicBool>,
    join: tokio::task::JoinHandle<()>,
}

/// Manages the lifecycle of the active room's [`Timeline`].
pub(crate) struct TimelineManager {
    current: Mutex<Option<TimelineGeneration>>,
}

impl TimelineManager {
    pub fn new() -> Self {
        Self {
            current: Mutex::new(None),
        }
    }

    /// The currently-open room, if a timeline is active.
    fn active_room_id(&self) -> Option<OwnedRoomId> {
        self.current
            .lock()
            .unwrap()
            .as_ref()
            .map(|g| g.room_id.clone())
    }

    /// The active timeline handle, if it matches `room_id`. Send operations use
    /// this so they act on the room the user actually has open.
    fn timeline_for(&self, room_id: &RoomId) -> Option<Arc<Timeline>> {
        let guard = self.current.lock().unwrap();
        guard
            .as_ref()
            .filter(|g| g.room_id == room_id)
            .map(|g| g.timeline.clone())
    }

    /// Build and subscribe to the timeline for `room_id`, replacing any
    /// previously-active one. Emits an initial snapshot synchronously, then
    /// keeps emitting on every diff batch until torn down.
    pub fn start(
        &self,
        client: &Client,
        runtime: &tokio::runtime::Runtime,
        room_id: &str,
        listener: Arc<dyn TimelineListener>,
    ) -> Result<()> {
        let owned_room_id = RoomId::parse(room_id).map_err(|e| ParlotteError::Room {
            message: format!("invalid room ID: {e}"),
        })?;

        // Tear down the previous generation first (awaits its aborted task so
        // the old Timeline — and the Client clone it holds — is released inside
        // the runtime).
        self.stop(runtime);

        let (timeline, stop_flag, join) = runtime.block_on(async {
            let room = client
                .get_room(&owned_room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {owned_room_id} not found"),
                })?;

            let timeline = Arc::new(room.timeline().await.map_err(|e| ParlotteError::Room {
                message: format!("failed to build timeline: {e}"),
            })?);

            // Load a screenful of recent history up front. The event cache only
            // holds events seen since it was subscribed, so a freshly-opened
            // room can otherwise start empty; an initial back-pagination fetches
            // recent messages so the timeline isn't blank. Best-effort: ignore
            // errors (e.g. transient network) — live events and later
            // pagination still fill in.
            let _ = timeline.paginate_backwards(30).await;

            // `subscribe` returns the current items plus a stream of subsequent
            // diff batches. Emit the initial snapshot now so the UI has content
            // before the first diff arrives, then keep a local mirror and emit
            // a fresh snapshot after applying each batch.
            let (initial, stream) = timeline.subscribe().await;
            listener.on_timeline_update(snapshot(&initial));

            let stop_flag = Arc::new(AtomicBool::new(false));
            let loop_stop = stop_flag.clone();
            let loop_listener = listener.clone();

            let join = tokio::spawn(async move {
                pin_mut!(stream);
                let mut items: Vector<Arc<TimelineItem>> = initial;
                while let Some(diffs) = stream.next().await {
                    if loop_stop.load(Ordering::SeqCst) {
                        break;
                    }
                    for diff in diffs {
                        diff.apply(&mut items);
                    }
                    if loop_stop.load(Ordering::SeqCst) {
                        break;
                    }
                    loop_listener.on_timeline_update(snapshot(&items));
                }
            });

            Ok::<_, ParlotteError>((timeline, stop_flag, join))
        })?;

        *self.current.lock().unwrap() = Some(TimelineGeneration {
            room_id: owned_room_id,
            timeline,
            stop_flag,
            join,
        });

        Ok(())
    }

    /// Paginate backwards (load older history). New items arrive through the
    /// subscription, producing a fresh snapshot. Returns `true` if the start of
    /// the room has been reached.
    pub fn paginate_back(
        &self,
        runtime: &tokio::runtime::Runtime,
        room_id: &str,
        num_events: u16,
    ) -> Result<bool> {
        let room_id = RoomId::parse(room_id).map_err(|e| ParlotteError::Room {
            message: format!("invalid room ID: {e}"),
        })?;
        let Some(timeline) = self.timeline_for(&room_id) else {
            return Ok(true);
        };
        runtime.block_on(async {
            timeline
                .paginate_backwards(num_events)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to paginate: {e}"),
                })
        })
    }

    /// Send a plain-text message to the active room as a local echo.
    pub fn send_message(
        &self,
        runtime: &tokio::runtime::Runtime,
        room_id: &str,
        body: &str,
    ) -> Result<()> {
        let room_id = RoomId::parse(room_id).map_err(|e| ParlotteError::Room {
            message: format!("invalid room ID: {e}"),
        })?;
        let timeline = self.require_timeline(&room_id)?;
        let content =
            AnyMessageLikeEventContent::RoomMessage(RoomMessageEventContent::text_plain(body));
        runtime.block_on(async {
            timeline
                .send(content)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to send message: {e}"),
                })
        })?;
        Ok(())
    }

    /// Send a reply to `in_reply_to` in the active room as a local echo.
    pub fn send_reply(
        &self,
        runtime: &tokio::runtime::Runtime,
        room_id: &str,
        in_reply_to: &str,
        body: &str,
    ) -> Result<()> {
        let room_id = RoomId::parse(room_id).map_err(|e| ParlotteError::Room {
            message: format!("invalid room ID: {e}"),
        })?;
        let event_id = EventId::parse(in_reply_to).map_err(|e| ParlotteError::Room {
            message: format!("invalid event ID: {e}"),
        })?;
        let timeline = self.require_timeline(&room_id)?;
        let content = RoomMessageEventContentWithoutRelation::text_plain(body);
        runtime.block_on(async {
            timeline
                .send_reply(content, event_id)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to send reply: {e}"),
                })
        })?;
        Ok(())
    }

    /// Toggle a reaction on a message in the active room. Adds the reaction if
    /// absent, removes it if the current user already reacted with `key`.
    /// Produces a local echo.
    pub fn toggle_reaction(
        &self,
        runtime: &tokio::runtime::Runtime,
        room_id: &str,
        target_event_id: &str,
        key: &str,
    ) -> Result<()> {
        let room_id = RoomId::parse(room_id).map_err(|e| ParlotteError::Room {
            message: format!("invalid room ID: {e}"),
        })?;
        let event_id = EventId::parse(target_event_id).map_err(|e| ParlotteError::Room {
            message: format!("invalid event ID: {e}"),
        })?;
        let timeline = self.require_timeline(&room_id)?;
        let item_id = TimelineEventItemId::EventId(event_id);
        runtime.block_on(async {
            timeline
                .toggle_reaction(&item_id, key)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to toggle reaction: {e}"),
                })
        })?;
        Ok(())
    }

    fn require_timeline(&self, room_id: &RoomId) -> Result<Arc<Timeline>> {
        self.timeline_for(room_id)
            .ok_or_else(|| ParlotteError::Room {
                message: "no active timeline for this room".to_owned(),
            })
    }

    /// Whether a timeline is currently active for `room_id`.
    pub fn is_active(&self, room_id: &str) -> bool {
        self.active_room_id()
            .is_some_and(|active| active.as_str() == room_id)
    }

    /// Tear down the active generation (synchronously). Signals the task to
    /// stop, aborts it, and awaits it so the Timeline's Client clone is freed
    /// inside the runtime.
    pub fn stop(&self, runtime: &tokio::runtime::Runtime) {
        let generation = { self.current.lock().unwrap().take() };
        if let Some(generation) = generation {
            generation.stop_flag.store(true, Ordering::SeqCst);
            generation.join.abort();
            runtime.block_on(async {
                let _ = generation.join.await;
            });
        }
    }

    /// Async teardown used from `ParlotteClient::Drop`: awaits the aborted task
    /// so every clone of the room's `Client` (held by the Timeline) is released
    /// inside the runtime, before the SQLite pool is torn down.
    pub async fn drain(&self) {
        let generation = { self.current.lock().unwrap().take() };
        if let Some(generation) = generation {
            generation.stop_flag.store(true, Ordering::SeqCst);
            generation.join.abort();
            let _ = generation.join.await;
            // Drop the Timeline (last strong ref here) inside the runtime.
            drop(generation.timeline);
        }
    }
}

/// Map the timeline's current items to renderable `MessageInfo`s, oldest first.
/// Virtual items (date dividers, read markers) and non-message events
/// (membership/state changes, polls, stickers) are skipped.
fn snapshot(items: &Vector<Arc<TimelineItem>>) -> Vec<MessageInfo> {
    items
        .iter()
        .filter_map(|item| timeline_item_to_message(item))
        .collect()
}

fn timeline_item_to_message(item: &TimelineItem) -> Option<MessageInfo> {
    let ev = item.as_event()?;
    let item_id = item.unique_id().0.clone();

    let send_state = match ev.send_state() {
        None => String::new(),
        Some(EventSendState::NotSentYet { .. }) => "sending".to_owned(),
        Some(EventSendState::SendingFailed { .. }) => "failed".to_owned(),
        Some(EventSendState::Sent { .. }) => "sent".to_owned(),
    };

    let event_id = ev.event_id().map(|e| e.to_string()).unwrap_or_default();
    let sender = ev.sender().to_string();
    let timestamp_ms: u64 = ev.timestamp().0.into();

    match ev.content() {
        TimelineItemContent::MsgLike(msglike) => {
            let replied_to_event_id = msglike.in_reply_to.as_ref().map(|d| d.event_id.to_string());
            let reactions = collect_reactions(msglike);

            match &msglike.kind {
                MsgLikeKind::Message(message) => {
                    let msgtype = message.msgtype();
                    let (body, formatted_body) = extract_body_and_formatted(msgtype);
                    let message_type = message_type_str(msgtype).to_owned();
                    let (media_source, media_mime_type, media_width, media_height, media_size) =
                        extract_media_info(msgtype);
                    Some(MessageInfo {
                        item_id,
                        send_state,
                        event_id,
                        sender,
                        body,
                        formatted_body,
                        message_type,
                        timestamp_ms,
                        is_edited: message.is_edited(),
                        replied_to_event_id,
                        media_source,
                        media_mime_type,
                        media_width,
                        media_height,
                        media_size,
                        reactions,
                    })
                }
                MsgLikeKind::UnableToDecrypt(_) => Some(MessageInfo {
                    item_id,
                    send_state,
                    event_id,
                    sender,
                    body: "Unable to decrypt message".to_owned(),
                    formatted_body: None,
                    message_type: "encrypted".to_owned(),
                    timestamp_ms,
                    is_edited: false,
                    replied_to_event_id,
                    media_source: None,
                    media_mime_type: None,
                    media_width: None,
                    media_height: None,
                    media_size: None,
                    reactions,
                }),
                // Redacted messages, stickers, polls, locations and other
                // message-like kinds are not rendered by the current UI.
                _ => None,
            }
        }
        // State changes, membership changes, call events, etc. are not shown.
        _ => None,
    }
}

/// Flatten the timeline's reaction aggregation (key -> sender -> info) into our
/// flat `ReactionInfo` list. Remote reactions carry the reaction event id
/// (needed for redaction); local echoes don't have one yet.
fn collect_reactions(msglike: &matrix_sdk_ui::timeline::MsgLikeContent) -> Vec<ReactionInfo> {
    let mut out = Vec::new();
    for (key, by_user) in msglike.reactions.iter() {
        for (user_id, info) in by_user.iter() {
            let event_id = match &info.status {
                ReactionStatus::RemoteToRemote(eid) => eid.to_string(),
                _ => String::new(),
            };
            out.push(ReactionInfo {
                event_id,
                key: key.clone(),
                sender: user_id.to_string(),
            });
        }
    }
    out
}
