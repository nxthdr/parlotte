use matrix_sdk::config::SyncSettings;
use matrix_sdk::event_handler::EventHandlerHandle;
use matrix_sdk::ruma::events::typing::SyncTypingEvent;
use matrix_sdk::Client;
use matrix_sdk::LoopCtrl;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::error::{ParlotteError, Result};

/// Callback trait for sync events.
/// Called on each successful sync response so the UI layer can refresh.
pub trait SyncListener: Send + Sync + 'static {
    fn on_sync_update(&self);

    /// Called when typing state changes in a room.
    /// `user_ids` contains the full set of currently-typing users (not a delta).
    fn on_typing_update(&self, _room_id: String, _user_ids: Vec<String>) {}

    /// Called when the persistent sync loop has stopped and will deliver no
    /// further updates. `error` is `None` for a clean stop (the caller asked
    /// it to stop) and `Some(message)` if the loop gave up after repeated
    /// transport failures. The platform layer can use this to surface a
    /// "reconnecting"/"offline" state or to restart sync.
    fn on_sync_stopped(&self, _error: Option<String>) {}
}

/// One running generation of the sync loop. Each `start_persistent_sync`
/// creates a fresh one; its `stop_flag` and task handle are owned solely by
/// this generation, so stopping or replacing it can never affect a different
/// generation (the bug that previously let a restart resurrect a dying loop).
struct SyncGeneration {
    stop_flag: Arc<AtomicBool>,
    join: tokio::task::JoinHandle<()>,
    client: Client,
    typing_handle: EventHandlerHandle,
    listener: Arc<dyn SyncListener>,
    reported: Arc<AtomicBool>,
}

/// Manages the Matrix sync loop lifecycle.
pub(crate) struct SyncManager {
    current: Mutex<Option<SyncGeneration>>,
}

impl SyncManager {
    pub fn new() -> Self {
        Self {
            current: Mutex::new(None),
        }
    }

    pub fn is_running(&self) -> bool {
        self.current
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|g| !g.join.is_finished())
    }

    /// Run a single sync request. Useful for tests and one-shot operations.
    pub async fn sync_once(client: &matrix_sdk::Client) -> Result<()> {
        client
            .sync_once(SyncSettings::default())
            .await
            .map_err(|e| ParlotteError::Sync {
                message: e.to_string(),
            })?;
        Ok(())
    }

    /// Tear down a generation: signal its loop to stop, abort the task (so an
    /// in-flight 30s long-poll doesn't delay teardown), and unregister its
    /// typing handler so handlers don't accumulate across restarts. Reports a
    /// clean stop to the listener exactly once (the aborted task can't, since
    /// abort drops its future before any post-loop code runs).
    fn shutdown_generation(gen: SyncGeneration) {
        gen.stop_flag.store(true, Ordering::SeqCst);
        gen.join.abort();
        gen.client.remove_event_handler(gen.typing_handle);
        if !gen.reported.swap(true, Ordering::SeqCst) {
            gen.listener.on_sync_stopped(None);
        }
    }

    /// Async teardown used from `ParlotteClient`'s `Drop`. Like `stop()`, but
    /// it also **awaits** the aborted sync task so the `Client` clone captured
    /// by the sync loop is released here — inside the tokio runtime. The
    /// matrix-sdk SQLite pool (deadpool) must be dropped with a live reactor;
    /// dropping it outside the runtime aborts the process. The generation's own
    /// `Client` clone (`gen.client`) is also dropped at the end of this call,
    /// still inside the runtime.
    pub async fn drain(&self) {
        // Take the generation out before any await so the std Mutex guard is
        // not held across a suspension point.
        let gen = { self.current.lock().unwrap().take() };
        if let Some(gen) = gen {
            gen.stop_flag.store(true, Ordering::SeqCst);
            gen.client.remove_event_handler(gen.typing_handle);
            gen.join.abort();
            let _ = gen.join.await;
            if !gen.reported.swap(true, Ordering::SeqCst) {
                gen.listener.on_sync_stopped(None);
            }
        }
    }

    /// Start a persistent sync loop in the background.
    ///
    /// If a previous loop is still running it is stopped first, so this is
    /// always safe to call (logout/login, foreground/background). The listener
    /// is called after each successful sync response. Uses long-polling with a
    /// 30-second timeout, and retries with exponential backoff on transport
    /// errors instead of dying silently on the first network blip.
    pub fn start_persistent_sync(
        &self,
        client: matrix_sdk::Client,
        runtime: &tokio::runtime::Runtime,
        listener: Arc<dyn SyncListener>,
    ) -> Result<()> {
        let mut current = self.current.lock().unwrap();

        // Replace any existing generation cleanly.
        if let Some(previous) = current.take() {
            Self::shutdown_generation(previous);
        }

        let stop_flag = Arc::new(AtomicBool::new(false));
        let reported = Arc::new(AtomicBool::new(false));

        // Register a global event handler for typing notifications. Stored on
        // the generation so it is removed when this loop stops.
        let typing_listener = listener.clone();
        let typing_handle =
            client.add_event_handler(move |event: SyncTypingEvent, room: matrix_sdk::Room| {
                let listener = typing_listener.clone();
                async move {
                    let room_id = room.room_id().to_string();
                    let user_ids: Vec<String> = event
                        .content
                        .user_ids
                        .iter()
                        .map(|uid| uid.to_string())
                        .collect();
                    listener.on_typing_update(room_id, user_ids);
                }
            });

        let settings = SyncSettings::default().timeout(Duration::from_secs(30));
        let loop_client = client.clone();
        let loop_stop = stop_flag.clone();

        let loop_listener = listener.clone();
        let join = runtime.spawn(async move {
            tracing::debug!("persistent sync loop starting");
            let mut backoff = Duration::from_secs(1);
            let max_backoff = Duration::from_secs(30);

            // Retry transport errors indefinitely with exponential backoff:
            // a network blip or laptop sleep must not silently kill sync (it
            // used to die on the first error). The loop only ends via a stop
            // request — and teardown, not this task, reports that, because a
            // stop aborts this task before any post-loop code could run.
            loop {
                if loop_stop.load(Ordering::SeqCst) {
                    break;
                }

                let cb_listener = loop_listener.clone();
                let cb_stop = loop_stop.clone();
                let result = loop_client
                    .sync_with_callback(settings.clone(), |_response| {
                        let listener = cb_listener.clone();
                        let stop_flag = cb_stop.clone();
                        async move {
                            // Check before notifying so no update fires after
                            // a stop has been requested.
                            if stop_flag.load(Ordering::SeqCst) {
                                return LoopCtrl::Break;
                            }
                            listener.on_sync_update();
                            if stop_flag.load(Ordering::SeqCst) {
                                LoopCtrl::Break
                            } else {
                                LoopCtrl::Continue
                            }
                        }
                    })
                    .await;

                match result {
                    // Clean break requested via LoopCtrl::Break.
                    Ok(()) => break,
                    Err(e) => {
                        if loop_stop.load(Ordering::SeqCst) {
                            break;
                        }
                        tracing::warn!("persistent sync errored, retrying in {backoff:?}: {e}");
                        tokio::time::sleep(backoff).await;
                        backoff = (backoff * 2).min(max_backoff);
                        continue;
                    }
                }
            }
            tracing::debug!("persistent sync loop ended");
        });

        *current = Some(SyncGeneration {
            stop_flag,
            join,
            client,
            typing_handle,
            listener,
            reported,
        });

        Ok(())
    }

    /// Stop the persistent sync loop, if one is running. Idempotent.
    pub fn stop(&self) {
        if let Some(gen) = self.current.lock().unwrap().take() {
            Self::shutdown_generation(gen);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_manager_initial_state() {
        let mgr = SyncManager::new();
        assert!(!mgr.is_running());
    }

    #[test]
    fn sync_manager_stop_when_not_running() {
        let mgr = SyncManager::new();
        // Stopping when not running should be a no-op.
        mgr.stop();
        assert!(!mgr.is_running());
    }

    #[test]
    fn sync_manager_stop_is_idempotent() {
        let mgr = SyncManager::new();
        mgr.stop();
        mgr.stop();
        assert!(!mgr.is_running());
    }
}
