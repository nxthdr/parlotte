use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::authentication::oauth::registration::{
    ApplicationType, ClientMetadata, Localized, OAuthGrantType,
};
use matrix_sdk::authentication::oauth::{ClientId, OAuthSession, UserSession};
use matrix_sdk::encryption::recovery::IdentityResetHandle;
use matrix_sdk::encryption::CrossSigningResetAuthType;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;
use matrix_sdk::ruma::events::AnySyncTimelineEvent;
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::ruma::{OwnedRoomId, RoomId};
use matrix_sdk::store::RoomLoadSettings;
use matrix_sdk::utils::UrlOrQuery;
use matrix_sdk::{Client, SessionMeta, SessionTokens};
use std::collections::HashMap;
use std::sync::Arc;

use crate::error::{ParlotteError, Result};
use crate::message::{
    LoginMethods, MatrixSessionData, MessageBatch, MessageInfo, OidcSessionData, ReactionInfo,
    SessionInfo, SsoProvider, UserProfile,
};
use crate::recovery::RecoveryState;
use crate::room::{PublicRoomInfo, RoomInfo, RoomMemberInfo};
use crate::session::{SessionChangeEvent, SessionChangeListener};
use crate::sync::{SyncListener, SyncManager};
use crate::verification::{
    self, ActiveVerification, SharedActive, VerificationListener, VerificationRequestInfo,
    VerificationState,
};
use matrix_sdk::encryption::verification::VerificationRequestState as SdkRequestState;

/// The main Parlotte client wrapping the Matrix SDK.
pub struct ParlotteClient {
    /// Wrapped in Option so Drop can take ownership and drop it inside the runtime.
    inner: Option<Client>,
    runtime: tokio::runtime::Runtime,
    sync_manager: SyncManager,
    active_verification: SharedActive,
    /// In-progress cross-signing identity reset. Populated by
    /// `begin_reset_identity` when the server requires OAuth/UIAA approval,
    /// consumed by `finish_reset_identity` or `cancel_reset_identity`.
    active_reset: Arc<tokio::sync::Mutex<Option<IdentityResetHandle>>>,
    /// Event-handler handle for the current verification-request listener, so
    /// re-registering replaces it instead of stacking a second handler.
    verification_handle: std::sync::Mutex<Option<matrix_sdk::event_handler::EventHandlerHandle>>,
    /// Task running the current session-change subscription loop, aborted when
    /// the listener is replaced so old listeners stop receiving events.
    session_change_task: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl ParlotteClient {
    /// Access the inner client, panicking if already shut down.
    fn client(&self) -> &Client {
        self.inner.as_ref().expect("client already shut down")
    }

    /// Create a new client connected to the given homeserver.
    ///
    /// `store_path` is the directory where the SQLite database will be stored.
    /// Pass `None` to use an in-memory store (useful for tests).
    pub fn new(homeserver_url: &str, store_path: Option<&str>) -> Result<Self> {
        let runtime = tokio::runtime::Runtime::new().map_err(|e| ParlotteError::Unknown {
            message: format!("failed to create tokio runtime: {e}"),
        })?;

        let client = runtime.block_on(async {
            let mut builder = Client::builder()
                .homeserver_url(homeserver_url)
                .handle_refresh_tokens();

            if let Some(path) = store_path {
                builder = builder.sqlite_store(path, None);
            }

            builder.build().await.map_err(|e| ParlotteError::Network {
                message: e.to_string(),
            })
        })?;

        Ok(Self {
            inner: Some(client),
            runtime,
            sync_manager: SyncManager::new(),
            active_verification: Arc::new(tokio::sync::Mutex::new(ActiveVerification::default())),
            active_reset: Arc::new(tokio::sync::Mutex::new(None)),
            verification_handle: std::sync::Mutex::new(None),
            session_change_task: std::sync::Mutex::new(None),
        })
    }

    /// Query the homeserver for supported login methods.
    pub fn login_methods(&self) -> Result<LoginMethods> {
        use matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType;

        let client = self.client();
        self.runtime.block_on(async {
            let response =
                client
                    .matrix_auth()
                    .get_login_types()
                    .await
                    .map_err(|e| ParlotteError::Auth {
                        message: format!("failed to get login types: {e}"),
                    })?;

            let mut supports_password = false;
            let mut supports_sso = false;
            let mut sso_providers = Vec::new();

            for flow in &response.flows {
                match flow {
                    LoginType::Password(_) => supports_password = true,
                    LoginType::Sso(sso) => {
                        supports_sso = true;
                        for idp in &sso.identity_providers {
                            sso_providers.push(SsoProvider {
                                id: idp.id.clone(),
                                name: idp.name.clone(),
                            });
                        }
                    }
                    _ => {}
                }
            }

            let supports_oidc = client.oauth().server_metadata().await.is_ok();

            Ok(LoginMethods {
                supports_password,
                supports_sso,
                sso_providers,
                supports_oidc,
            })
        })
    }

    /// Get the URL to redirect the user to for SSO login.
    /// After authentication, the homeserver redirects to `redirect_url` with a `loginToken` parameter.
    pub fn sso_login_url(&self, redirect_url: &str, idp_id: Option<&str>) -> Result<String> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .matrix_auth()
                .get_sso_login_url(redirect_url, idp_id)
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("failed to get SSO login URL: {e}"),
                })
        })
    }

    /// Complete SSO login using the callback URL containing the loginToken.
    pub fn login_sso_callback(&self, callback_url: &str) -> Result<SessionInfo> {
        let client = self.client();
        self.runtime.block_on(async {
            let url = url::Url::parse(callback_url).map_err(|e| ParlotteError::Auth {
                message: format!("invalid callback URL: {e}"),
            })?;

            client
                .matrix_auth()
                .login_with_sso_callback(UrlOrQuery::Url(url))
                .map_err(|e| ParlotteError::Auth {
                    message: format!("SSO callback failed: {e}"),
                })?
                .initial_device_display_name("Parlotte")
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("SSO login failed: {e}"),
                })?;

            let user_id = client
                .user_id()
                .ok_or_else(|| ParlotteError::Auth {
                    message: "no user_id after SSO login".to_string(),
                })?
                .to_string();

            let device_id = client
                .device_id()
                .ok_or_else(|| ParlotteError::Auth {
                    message: "no device_id after SSO login".to_string(),
                })?
                .to_string();

            Ok(SessionInfo { user_id, device_id })
        })
    }

    /// Log in with username and password.
    pub fn login(&self, username: &str, password: &str) -> Result<SessionInfo> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .matrix_auth()
                .login_username(username, password)
                .send()
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: e.to_string(),
                })?;

            let user_id = client
                .user_id()
                .ok_or_else(|| ParlotteError::Auth {
                    message: "no user_id after login".to_string(),
                })?
                .to_string();

            let device_id = client
                .device_id()
                .ok_or_else(|| ParlotteError::Auth {
                    message: "no device_id after login".to_string(),
                })?
                .to_string();

            Ok(SessionInfo { user_id, device_id })
        })
    }

    /// Get the current session data for persistence.
    /// Returns None if not logged in.
    pub fn session(&self) -> Option<MatrixSessionData> {
        let session = self.client().matrix_auth().session()?;
        Some(MatrixSessionData {
            user_id: session.meta.user_id.to_string(),
            device_id: session.meta.device_id.to_string(),
            access_token: session.tokens.access_token,
        })
    }

    /// Restore a previously saved session.
    pub fn restore_session(&self, session_data: MatrixSessionData) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let user_id = matrix_sdk::ruma::UserId::parse(&session_data.user_id).map_err(|e| {
                ParlotteError::Auth {
                    message: format!("invalid user ID: {e}"),
                }
            })?;
            let device_id: matrix_sdk::ruma::OwnedDeviceId = session_data.device_id.into();

            let session = MatrixSession {
                meta: SessionMeta { user_id, device_id },
                tokens: SessionTokens {
                    access_token: session_data.access_token,
                    refresh_token: None,
                },
            };

            client
                .matrix_auth()
                .restore_session(session, RoomLoadSettings::default())
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("failed to restore session: {e}"),
                })?;

            Ok(())
        })
    }

    /// Begin an MSC3861 OIDC login. Dynamically registers the client with the
    /// homeserver's auth service, then returns an authorization URL for the
    /// user to open in a browser. `redirect_uri` must be a custom-scheme URL
    /// the app can catch (e.g. `dev.nxthdr.parlotte:/oauth-callback`).
    pub fn oidc_login_url(&self, redirect_uri: &str) -> Result<String> {
        let client = self.client();
        self.runtime.block_on(async {
            let redirect = url::Url::parse(redirect_uri).map_err(|e| ParlotteError::Auth {
                message: format!("invalid redirect URI: {e}"),
            })?;

            let metadata = build_client_metadata(redirect.clone())?;

            let data = client
                .oauth()
                .login(
                    redirect,
                    None,
                    Some(
                        Raw::new(&metadata)
                            .map_err(|e| ParlotteError::Auth {
                                message: format!("failed to serialize client metadata: {e}"),
                            })?
                            .into(),
                    ),
                    None,
                )
                .build()
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("failed to build OIDC login URL: {e}"),
                })?;

            Ok(data.url.to_string())
        })
    }

    /// Complete the OIDC login with the full redirect URL the browser was sent
    /// to (including the `code` and `state` query parameters).
    pub fn oidc_finish_login(&self, callback_url: &str) -> Result<SessionInfo> {
        let client = self.client();
        self.runtime.block_on(async {
            let url = url::Url::parse(callback_url).map_err(|e| ParlotteError::Auth {
                message: format!("invalid callback URL: {e}"),
            })?;

            client
                .oauth()
                .finish_login(UrlOrQuery::Url(url))
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("OIDC finish_login failed: {e}"),
                })?;

            let user_id = client
                .user_id()
                .ok_or_else(|| ParlotteError::Auth {
                    message: "no user_id after OIDC login".to_string(),
                })?
                .to_string();

            let device_id = client
                .device_id()
                .ok_or_else(|| ParlotteError::Auth {
                    message: "no device_id after OIDC login".to_string(),
                })?
                .to_string();

            Ok(SessionInfo { user_id, device_id })
        })
    }

    /// Get the current OIDC session for persistence. Returns None if not
    /// logged in via OIDC.
    pub fn oidc_session(&self) -> Option<OidcSessionData> {
        let session = self.client().oauth().full_session()?;
        Some(OidcSessionData {
            user_id: session.user.meta.user_id.to_string(),
            device_id: session.user.meta.device_id.to_string(),
            access_token: session.user.tokens.access_token,
            refresh_token: session.user.tokens.refresh_token,
            client_id: session.client_id.as_str().to_owned(),
        })
    }

    /// Register a listener that is invoked whenever matrix-sdk refreshes the
    /// OIDC access/refresh tokens or observes an `M_UNKNOWN_TOKEN` logout.
    /// Should be called after every login/restore so rotated refresh tokens
    /// get persisted — MAS invalidates the previous refresh token once a new
    /// one is minted.
    pub fn set_session_change_listener(&self, listener: Arc<dyn SessionChangeListener>) {
        let client = self.client().clone();
        let task = self.runtime.spawn(async move {
            let mut rx = client.subscribe_to_session_changes();
            loop {
                let change = match rx.recv().await {
                    Ok(c) => c,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                };
                match change {
                    matrix_sdk::SessionChange::TokensRefreshed => {
                        if let Some(s) = client.oauth().full_session() {
                            let session = OidcSessionData {
                                user_id: s.user.meta.user_id.to_string(),
                                device_id: s.user.meta.device_id.to_string(),
                                access_token: s.user.tokens.access_token,
                                refresh_token: s.user.tokens.refresh_token,
                                client_id: s.client_id.as_str().to_owned(),
                            };
                            listener
                                .on_session_change(SessionChangeEvent::TokensRefreshed { session });
                        } else {
                            tracing::warn!(
                                "TokensRefreshed fired but client.oauth().full_session() returned None"
                            );
                        }
                    }
                    matrix_sdk::SessionChange::UnknownToken(data) => {
                        listener.on_session_change(SessionChangeEvent::UnknownToken {
                            soft_logout: data.soft_logout,
                        });
                    }
                }
            }
        });

        // Replace any previous subscription so old listeners stop firing and
        // their tasks don't accumulate across re-registration (re-login).
        if let Some(previous) = self.session_change_task.lock().unwrap().replace(task) {
            previous.abort();
        }
    }

    /// Restore a previously-saved OIDC session.
    pub fn oidc_restore_session(&self, data: OidcSessionData) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let user_id = matrix_sdk::ruma::UserId::parse(&data.user_id).map_err(|e| {
                ParlotteError::Auth {
                    message: format!("invalid user ID: {e}"),
                }
            })?;
            let device_id: matrix_sdk::ruma::OwnedDeviceId = data.device_id.into();

            let session = OAuthSession {
                client_id: ClientId::new(data.client_id),
                user: UserSession {
                    meta: SessionMeta { user_id, device_id },
                    tokens: SessionTokens {
                        access_token: data.access_token,
                        refresh_token: data.refresh_token,
                    },
                },
            };

            client
                .oauth()
                .restore_session(session, RoomLoadSettings::default())
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("failed to restore OIDC session: {e}"),
                })?;

            Ok(())
        })
    }

    /// Get the profile (display name and avatar URL) of the logged-in user.
    pub fn get_profile(&self) -> Result<UserProfile> {
        let client = self.client();
        self.runtime.block_on(async {
            let account = client.account();
            let display_name =
                account
                    .get_display_name()
                    .await
                    .map_err(|e| ParlotteError::Network {
                        message: format!("failed to get display name: {e}"),
                    })?;
            let avatar_url = account
                .get_avatar_url()
                .await
                .map_err(|e| ParlotteError::Network {
                    message: format!("failed to get avatar URL: {e}"),
                })?
                .map(|u| u.to_string());

            Ok(UserProfile {
                display_name,
                avatar_url,
            })
        })
    }

    /// Set the display name of the logged-in user.
    pub fn set_display_name(&self, name: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .account()
                .set_display_name(Some(name))
                .await
                .map_err(|e| ParlotteError::Network {
                    message: format!("failed to set display name: {e}"),
                })
        })
    }

    /// Upload avatar image data and set it as the logged-in user's avatar.
    /// `mime_type` must be a valid image media type (e.g. `"image/png"`).
    /// `data` is the raw image bytes.
    pub fn set_avatar(&self, mime_type: &str, data: Vec<u8>) -> Result<String> {
        let mime: mime::Mime =
            mime_type
                .parse()
                .map_err(|e: mime::FromStrError| ParlotteError::Unknown {
                    message: format!("invalid MIME type {mime_type:?}: {e}"),
                })?;

        let client = self.client();
        self.runtime.block_on(async {
            let mxc_url = client
                .account()
                .upload_avatar(&mime, data)
                .await
                .map_err(|e| ParlotteError::Network {
                    message: format!("failed to upload avatar: {e}"),
                })?;

            Ok(mxc_url.to_string())
        })
    }

    /// Remove the logged-in user's avatar.
    pub fn remove_avatar(&self) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .account()
                .set_avatar_url(None)
                .await
                .map_err(|e| ParlotteError::Network {
                    message: format!("failed to remove avatar: {e}"),
                })
        })
    }

    /// Ignore a user globally (`m.ignored_user_list`). Their events are
    /// filtered out of sync responses by the server.
    pub fn ignore_user(&self, user_id: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Unknown {
                    message: format!("invalid user ID: {e}"),
                })?;

            tracing::debug!(%user_id, "ignoring user");
            client
                .account()
                .ignore_user(&user_id)
                .await
                .map_err(|e| ParlotteError::Network {
                    message: format!("failed to ignore user: {e}"),
                })
        })
    }

    /// Remove a user from the global ignore list.
    pub fn unignore_user(&self, user_id: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Unknown {
                    message: format!("invalid user ID: {e}"),
                })?;

            tracing::debug!(%user_id, "unignoring user");
            client
                .account()
                .unignore_user(&user_id)
                .await
                .map_err(|e| ParlotteError::Network {
                    message: format!("failed to unignore user: {e}"),
                })
        })
    }

    /// Get the list of ignored user IDs from `m.ignored_user_list` account data.
    pub fn ignored_users(&self) -> Result<Vec<String>> {
        use matrix_sdk::ruma::events::ignored_user_list::IgnoredUserListEventContent;

        let client = self.client();
        self.runtime.block_on(async {
            let raw = client
                .account()
                .account_data::<IgnoredUserListEventContent>()
                .await
                .map_err(|e| ParlotteError::Store {
                    message: format!("failed to read ignored user list: {e}"),
                })?;

            let Some(raw) = raw else {
                return Ok(Vec::new());
            };

            let content = raw.deserialize().map_err(|e| ParlotteError::Store {
                message: format!("failed to parse ignored user list: {e}"),
            })?;

            Ok(content
                .ignored_users
                .keys()
                .map(|user_id| user_id.to_string())
                .collect())
        })
    }

    /// Log out and invalidate the current session.
    ///
    /// Uses `Client::logout`, which dispatches to the active auth API: a plain
    /// `/logout` for password/SSO sessions, or OAuth token revocation for OIDC
    /// (MSC3861) sessions. The previous `matrix_auth().logout()` left OIDC
    /// access/refresh tokens un-revoked at the provider.
    pub fn logout(&self) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            self.sync_manager.stop();
            client.logout().await.map_err(|e| ParlotteError::Auth {
                message: e.to_string(),
            })?;
            Ok(())
        })
    }

    /// Get a list of all joined and invited rooms.
    pub fn rooms(&self) -> Result<Vec<RoomInfo>> {
        let client = self.client();
        self.runtime.block_on(async {
            let joined = client.joined_rooms();
            let invited = client.invited_rooms();
            tracing::debug!(
                joined = joined.len(),
                invited = invited.len(),
                "listing rooms"
            );
            let mut rooms = Vec::with_capacity(joined.len() + invited.len());

            for room in joined {
                let display_name = room
                    .display_name()
                    .await
                    .map(|dn| dn.to_string())
                    .unwrap_or_else(|_| "Unknown".to_string());

                let topic = room.topic();
                let is_encrypted = matches!(
                    room.encryption_state(),
                    matrix_sdk::EncryptionState::Encrypted
                );

                let is_public = room.is_public().unwrap_or(false);
                let is_direct = room.is_direct().await.unwrap_or(false);

                let counts = room.unread_notification_counts();
                let unread_count = if counts.notification_count > 0 {
                    counts.notification_count
                } else {
                    room.num_unread_messages()
                };

                rooms.push(RoomInfo {
                    id: room.room_id().to_string(),
                    display_name,
                    is_encrypted,
                    is_public,
                    is_direct,
                    topic,
                    is_invited: false,
                    unread_count,
                });
            }

            for room in invited {
                let display_name = room
                    .display_name()
                    .await
                    .map(|dn| dn.to_string())
                    .unwrap_or_else(|_| "Unknown".to_string());

                let topic = room.topic();
                let is_encrypted = matches!(
                    room.encryption_state(),
                    matrix_sdk::EncryptionState::Encrypted
                );

                let is_public = room.is_public().unwrap_or(false);
                let is_direct = room.is_direct().await.unwrap_or(false);

                rooms.push(RoomInfo {
                    id: room.room_id().to_string(),
                    display_name,
                    is_encrypted,
                    is_public,
                    is_direct,
                    topic,
                    is_invited: true,
                    unread_count: 0,
                });
            }

            Ok(rooms)
        })
    }

    /// Send a text message to a room.
    /// Send a plain-text message. Returns the event ID assigned by the server
    /// so the UI can match the optimistic placeholder to its real echo.
    pub fn send_message(&self, room_id: &str, body: &str) -> Result<String> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let content = RoomMessageEventContent::text_plain(body);
            let response = room.send(content).await.map_err(|e| ParlotteError::Room {
                message: format!("failed to send message: {e}"),
            })?;

            Ok(response.response.event_id.to_string())
        })
    }

    /// Send a reply to a specific message in a room. Returns the new event's ID.
    pub fn send_reply(&self, room_id: &str, event_id: &str, body: &str) -> Result<String> {
        use matrix_sdk::room::reply::{EnforceThread, Reply};
        use matrix_sdk::ruma::events::room::message::{
            AddMentions, RoomMessageEventContentWithoutRelation,
        };
        use matrix_sdk::ruma::EventId;

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let event_id = <&EventId>::try_from(event_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid event ID: {e}"),
            })?;

            let content = RoomMessageEventContentWithoutRelation::text_plain(body);
            let reply_content = room
                .make_reply_event(
                    content,
                    Reply {
                        event_id: event_id.to_owned(),
                        enforce_thread: EnforceThread::Unthreaded,
                        add_mentions: AddMentions::Yes,
                    },
                )
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to create reply: {e}"),
                })?;

            let response = room
                .send(reply_content)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to send reply: {e}"),
                })?;

            Ok(response.response.event_id.to_string())
        })
    }

    /// Get recent messages from a room, most recent last.
    /// Pass `from` as `None` to fetch the latest messages, or provide a pagination
    /// token from a previous `MessageBatch::end_token` to load older history.
    pub fn messages(&self, room_id: &str, limit: u64, from: Option<&str>) -> Result<MessageBatch> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let mut options = MessagesOptions::backward();
            options.limit =
                matrix_sdk::ruma::UInt::new(limit).unwrap_or(matrix_sdk::ruma::UInt::MAX);
            if let Some(token) = from {
                options.from = Some(token.to_owned());
            }

            let response = room
                .messages(options)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to fetch messages: {e}"),
                })?;

            use matrix_sdk::ruma::events::room::message::Relation;

            let mut messages = Vec::new();
            // Track edit candidates: original_event_id -> replacements in
            // newest-first order (the batch is iterated newest-first).
            let mut edits: HashMap<String, Vec<EditCandidate>> = HashMap::new();
            // Track reactions: target_event_id -> Vec<ReactionInfo>
            let mut reactions_map: HashMap<String, Vec<ReactionInfo>> = HashMap::new();

            for event in response.chunk {
                let raw = event.raw();
                let Ok(deserialized) = raw.deserialize() else {
                    continue;
                };

                // Collect m.reaction events
                if let AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Reaction(
                        matrix_sdk::ruma::events::SyncMessageLikeEvent::Original(original),
                    ),
                ) = &deserialized
                {
                    let annotation = &original.content.relates_to;
                    reactions_map
                        .entry(annotation.event_id.to_string())
                        .or_default()
                        .push(ReactionInfo {
                            event_id: original.event_id.to_string(),
                            key: annotation.key.clone(),
                            sender: original.sender.to_string(),
                        });
                }

                // Events the SDK couldn't decrypt arrive as `m.room.encrypted`.
                // Surface them as an explicit placeholder instead of silently
                // dropping them, so the timeline doesn't look like messages
                // went missing.
                if let AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomEncrypted(
                        matrix_sdk::ruma::events::SyncMessageLikeEvent::Original(original),
                    ),
                ) = &deserialized
                {
                    messages.push(MessageInfo {
                        event_id: original.event_id.to_string(),
                        sender: original.sender.to_string(),
                        body: "Unable to decrypt message".to_owned(),
                        formatted_body: None,
                        message_type: "encrypted".to_owned(),
                        timestamp_ms: original.origin_server_ts.0.into(),
                        is_edited: false,
                        replied_to_event_id: None,
                        media_source: None,
                        media_mime_type: None,
                        media_width: None,
                        media_height: None,
                        media_size: None,
                        reactions: vec![],
                    });
                    continue;
                }

                if let AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
                ) = deserialized
                {
                    let original = match msg {
                        matrix_sdk::ruma::events::SyncMessageLikeEvent::Original(o) => o,
                        // Redacted events are skipped
                        _ => continue,
                    };

                    // Check if this is an edit (replacement) event
                    if let Some(Relation::Replacement(replacement)) = &original.content.relates_to {
                        let (body, formatted) =
                            extract_body_and_formatted(&replacement.new_content.msgtype);
                        edits
                            .entry(replacement.event_id.to_string())
                            .or_default()
                            .push(EditCandidate {
                                body,
                                formatted_body: formatted,
                                sender: original.sender.to_string(),
                            });
                        continue;
                    }

                    let replied_to_event_id = match &original.content.relates_to {
                        Some(Relation::Reply(reply)) => {
                            Some(reply.in_reply_to.event_id.to_string())
                        }
                        _ => None,
                    };

                    let (body, formatted_body) =
                        extract_body_and_formatted(&original.content.msgtype);
                    let message_type = message_type_str(&original.content.msgtype).to_owned();
                    let (media_source, media_mime_type, media_width, media_height, media_size) =
                        extract_media_info(&original.content.msgtype);

                    messages.push(MessageInfo {
                        event_id: original.event_id.to_string(),
                        sender: original.sender.to_string(),
                        body,
                        formatted_body,
                        message_type,
                        timestamp_ms: original.origin_server_ts.0.into(),
                        is_edited: false,
                        replied_to_event_id,
                        media_source,
                        media_mime_type,
                        media_width,
                        media_height,
                        media_size,
                        reactions: vec![],
                    });
                }
            }

            // Apply edits to original messages
            apply_edits(&mut messages, edits);

            // Attach reactions to their target messages
            for msg in &mut messages {
                if let Some(rxns) = reactions_map.remove(&msg.event_id) {
                    msg.reactions = rxns;
                }
            }

            // Reverse so oldest is first, newest last
            messages.reverse();
            Ok(MessageBatch {
                messages,
                end_token: response.end,
            })
        })
    }

    /// Edit an existing message. Only the sender can edit their own messages.
    pub fn edit_message(&self, room_id: &str, event_id: &str, new_body: &str) -> Result<()> {
        use matrix_sdk::room::edit::EditedContent;
        use matrix_sdk::ruma::events::room::message::RoomMessageEventContentWithoutRelation;
        use matrix_sdk::ruma::EventId;

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let event_id = <&EventId>::try_from(event_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid event ID: {e}"),
            })?;

            let new_content = RoomMessageEventContentWithoutRelation::text_plain(new_body);
            let edit_content = room
                .make_edit_event(event_id, EditedContent::RoomMessage(new_content))
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to create edit: {e}"),
                })?;

            room.send(edit_content)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to send edit: {e}"),
                })?;

            Ok(())
        })
    }

    /// Redact (delete) a message. Users can redact their own messages, and
    /// moderators/admins can redact anyone's messages.
    pub fn redact_message(&self, room_id: &str, event_id: &str) -> Result<()> {
        use matrix_sdk::ruma::EventId;

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let event_id = <&EventId>::try_from(event_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid event ID: {e}"),
            })?;

            room.redact(event_id, None, None)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to redact message: {e}"),
                })?;

            Ok(())
        })
    }

    /// Send a reaction (emoji) on a message. Returns the reaction event ID.
    pub fn send_reaction(&self, room_id: &str, event_id: &str, key: &str) -> Result<String> {
        use matrix_sdk::ruma::events::reaction::ReactionEventContent;
        use matrix_sdk::ruma::events::relation::Annotation;
        use matrix_sdk::ruma::EventId;

        let client = self.client();
        self.runtime.block_on(async {
            // Validate both IDs before the room lookup so invalid input is
            // reported as such regardless of whether the room exists.
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let event_id = <&EventId>::try_from(event_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid event ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let content =
                ReactionEventContent::new(Annotation::new(event_id.to_owned(), key.to_owned()));
            let response = room.send(content).await.map_err(|e| ParlotteError::Room {
                message: format!("failed to send reaction: {e}"),
            })?;

            Ok(response.response.event_id.to_string())
        })
    }

    /// Redact (remove) a reaction event. The caller must pass the event ID
    /// of the m.reaction event, not the target message.
    pub fn redact_reaction(&self, room_id: &str, reaction_event_id: &str) -> Result<()> {
        use matrix_sdk::ruma::EventId;

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let event_id =
                <&EventId>::try_from(reaction_event_id).map_err(|e| ParlotteError::Room {
                    message: format!("invalid event ID: {e}"),
                })?;

            room.redact(event_id, None, None)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to redact reaction: {e}"),
                })?;

            Ok(())
        })
    }

    /// Set the display name of a room. Requires appropriate power level.
    pub fn set_room_name(&self, room_id: &str, name: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            room.set_name(name.to_owned())
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to set room name: {e}"),
                })?;

            Ok(())
        })
    }

    /// Set the topic of a room. Pass an empty string to clear it.
    /// Requires appropriate power level.
    pub fn set_room_topic(&self, room_id: &str, topic: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            room.set_room_topic(topic)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to set room topic: {e}"),
                })?;

            Ok(())
        })
    }

    /// Perform a single sync cycle. Useful for tests and initial sync.
    pub fn sync_once(&self) -> Result<()> {
        tracing::debug!("sync_once starting");
        let result = self.runtime.block_on(SyncManager::sync_once(self.client()));
        match &result {
            Ok(()) => tracing::debug!("sync_once completed"),
            Err(e) => tracing::warn!("sync_once failed: {e}"),
        }
        result
    }

    /// Start a persistent sync loop in the background.
    /// The listener is called after each successful sync response.
    /// Uses long-polling (30s timeout) instead of periodic polling.
    pub fn start_sync(&self, listener: Arc<dyn SyncListener>) -> Result<()> {
        self.sync_manager
            .start_persistent_sync(self.client().clone(), &self.runtime, listener)
    }

    /// Stop the persistent sync loop.
    pub fn stop_sync(&self) {
        self.sync_manager.stop();
    }

    /// Check if sync is currently running.
    pub fn is_syncing(&self) -> bool {
        self.sync_manager.is_running()
    }

    /// Access the underlying matrix_sdk::Client (for advanced usage / tests).
    pub fn inner(&self) -> &Client {
        self.client()
    }

    /// Create a room with the given name. Returns the room ID.
    /// If `is_public` is true, the room is listed in the directory and anyone can join.
    pub fn create_room(&self, name: &str, is_public: bool) -> Result<String> {
        use matrix_sdk::ruma::api::client::room::create_room::v3::Request as CreateRoomRequest;
        use matrix_sdk::ruma::api::client::room::Visibility;
        use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;
        use matrix_sdk::ruma::events::EmptyStateKey;
        use matrix_sdk::ruma::events::InitialStateEvent;

        let client = self.client();
        self.runtime.block_on(async {
            let mut request = CreateRoomRequest::new();
            request.name = Some(name.to_owned());

            if is_public {
                request.visibility = Visibility::Public;
                request.preset = Some(
                    matrix_sdk::ruma::api::client::room::create_room::v3::RoomPreset::PublicChat,
                );
            } else {
                // Private rooms are encrypted by default
                let encryption_content = RoomEncryptionEventContent::with_recommended_defaults();
                let encryption_event = InitialStateEvent::new(EmptyStateKey, encryption_content);
                request.initial_state.push(encryption_event.to_raw_any());
            }

            let response = client
                .create_room(request)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to create room: {e}"),
                })?;

            Ok(response.room_id().to_string())
        })
    }

    /// List public rooms from the server directory.
    pub fn public_rooms(&self) -> Result<Vec<PublicRoomInfo>> {
        use matrix_sdk::ruma::api::client::directory::get_public_rooms_filtered;

        let client = self.client();
        self.runtime.block_on(async {
            let request = get_public_rooms_filtered::v3::Request::new();
            let response =
                client
                    .public_rooms_filtered(request)
                    .await
                    .map_err(|e| ParlotteError::Room {
                        message: format!("failed to fetch public rooms: {e}"),
                    })?;

            Ok(response
                .chunk
                .into_iter()
                .map(|r| PublicRoomInfo {
                    id: r.room_id.to_string(),
                    name: r.name,
                    topic: r.topic,
                    member_count: r.num_joined_members.into(),
                    alias: r.canonical_alias.map(|a| a.to_string()),
                })
                .collect())
        })
    }

    /// Invite a user to a room.
    pub fn invite_user(&self, room_id: &str, user_id: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Room {
                    message: format!("invalid user ID: {e}"),
                })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            tracing::debug!(%user_id, %room_id, "inviting user to room");
            room.invite_user_by_id(&user_id)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to invite user: {e}"),
                })?;

            tracing::debug!(%user_id, %room_id, "invite sent successfully");
            Ok(())
        })
    }

    /// Explicitly shut down, dropping the inner client within the tokio runtime.
    /// This prevents panics from deadpool's connection pool cleanup.
    pub fn shutdown(self) {
        // Drop is implemented below to handle this automatically.
        drop(self);
    }

    /// Join a room by its ID.
    pub fn join_room(&self, room_id: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id =
                OwnedRoomId::try_from(room_id.to_owned()).map_err(|e| ParlotteError::Room {
                    message: format!("invalid room ID: {e}"),
                })?;

            client
                .join_room_by_id(&room_id)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to join room: {e}"),
                })?;

            Ok(())
        })
    }

    /// Leave a room by its ID.
    pub fn leave_room(&self, room_id: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            room.leave().await.map_err(|e| ParlotteError::Room {
                message: format!("failed to leave room: {e}"),
            })?;

            Ok(())
        })
    }

    /// Set a member's power level. Typical values: 0 (member), 50 (moderator),
    /// 100 (admin). Requires the current user to have a higher power level than
    /// the target's current and target levels.
    pub fn set_user_power_level(&self, room_id: &str, user_id: &str, level: i64) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Room {
                    message: format!("invalid user ID: {e}"),
                })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let level =
                matrix_sdk::ruma::Int::try_from(level).map_err(|e| ParlotteError::Room {
                    message: format!("power level out of range: {e}"),
                })?;

            tracing::debug!(%user_id, %room_id, %level, "setting user power level");
            room.update_power_levels(vec![(user_id.as_ref(), level)])
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to set power level: {e}"),
                })?;

            Ok(())
        })
    }

    /// Kick a user from a room. Reason is optional and shown to the kicked user.
    pub fn kick_user(&self, room_id: &str, user_id: &str, reason: Option<String>) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Room {
                    message: format!("invalid user ID: {e}"),
                })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            tracing::debug!(%user_id, %room_id, "kicking user");
            room.kick_user(&user_id, reason.as_deref())
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to kick user: {e}"),
                })?;

            Ok(())
        })
    }

    /// Ban a user from a room. Reason is optional.
    pub fn ban_user(&self, room_id: &str, user_id: &str, reason: Option<String>) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Room {
                    message: format!("invalid user ID: {e}"),
                })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            tracing::debug!(%user_id, %room_id, "banning user");
            room.ban_user(&user_id, reason.as_deref())
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to ban user: {e}"),
                })?;

            Ok(())
        })
    }

    /// Unban a previously-banned user.
    pub fn unban_user(&self, room_id: &str, user_id: &str, reason: Option<String>) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let user_id =
                matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| ParlotteError::Room {
                    message: format!("invalid user ID: {e}"),
                })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            tracing::debug!(%user_id, %room_id, "unbanning user");
            room.unban_user(&user_id, reason.as_deref())
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to unban user: {e}"),
                })?;

            Ok(())
        })
    }

    /// Send a read receipt for the given event in a room.
    pub fn send_read_receipt(&self, room_id: &str, event_id: &str) -> Result<()> {
        use matrix_sdk::ruma::events::receipt::ReceiptThread;
        use matrix_sdk::ruma::OwnedEventId;

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let event_id: OwnedEventId =
                event_id
                    .try_into()
                    .map_err(|e: matrix_sdk::ruma::IdParseError| ParlotteError::Room {
                        message: format!("invalid event ID: {e}"),
                    })?;

            room.send_single_receipt(
                matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType::Read,
                ReceiptThread::Unthreaded,
                event_id,
            )
            .await
            .map_err(|e| ParlotteError::Room {
                message: format!("failed to send read receipt: {e}"),
            })?;

            Ok(())
        })
    }

    /// Send a typing notice for the given room.
    /// The SDK internally debounces repeated calls with `is_typing: true`.
    pub fn send_typing_notice(&self, room_id: &str, is_typing: bool) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            room.typing_notice(is_typing)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to send typing notice: {e}"),
                })?;

            Ok(())
        })
    }

    /// Upload an attachment and post it as a message to the given room.
    ///
    /// `mime_type` must be a valid media type string (e.g. `"image/png"`). When
    /// the mime's top-level type is `image`, the attachment is sent as
    /// `m.image` with the provided dimensions; otherwise it is sent as
    /// `m.file`.
    /// Send a file/image attachment. Returns the event ID assigned by the
    /// server so the UI can resolve its optimistic placeholder.
    pub fn send_attachment(
        &self,
        room_id: &str,
        filename: &str,
        mime_type: &str,
        data: Vec<u8>,
        width: Option<u32>,
        height: Option<u32>,
    ) -> Result<String> {
        use matrix_sdk::attachment::{
            AttachmentConfig, AttachmentInfo, BaseFileInfo, BaseImageInfo,
        };
        use matrix_sdk::ruma::UInt;

        let mime: mime::Mime =
            mime_type
                .parse()
                .map_err(|e: mime::FromStrError| ParlotteError::Room {
                    message: format!("invalid MIME type {mime_type:?}: {e}"),
                })?;

        let size_uint = UInt::new(data.len() as u64);
        let info = if mime.type_() == mime::IMAGE {
            AttachmentInfo::Image(BaseImageInfo {
                width: width.map(UInt::from),
                height: height.map(UInt::from),
                size: size_uint,
                blurhash: None,
                is_animated: None,
            })
        } else {
            AttachmentInfo::File(BaseFileInfo { size: size_uint })
        };

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let config = AttachmentConfig::new().info(info);
            let response = room
                .send_attachment(filename.to_owned(), &mime, data, config)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to send attachment: {e}"),
                })?;

            Ok(response.event_id.to_string())
        })
    }

    /// Download the raw bytes of a media item.
    ///
    /// `media_source` is the serialised `MediaSource` JSON produced by
    /// `extract_media_info`. It may represent either a plain mxc:// URI or an
    /// encrypted file (with decryption keys), so encrypted-room media is
    /// handled transparently.
    ///
    /// For backwards-compatibility a bare `mxc://` URI string is also accepted.
    pub fn download_media(&self, media_source: &str) -> Result<Vec<u8>> {
        use matrix_sdk::media::{MediaFormat, MediaRequestParameters};
        use matrix_sdk::ruma::events::room::MediaSource;
        use matrix_sdk::ruma::OwnedMxcUri;

        // Try deserialising as full MediaSource JSON first; fall back to treating
        // the string as a plain mxc URI for callers that pass one directly.
        let source: MediaSource = serde_json::from_str(media_source)
            .unwrap_or_else(|_| MediaSource::Plain(OwnedMxcUri::from(media_source)));

        // Validate that whichever variant we ended up with has a valid mxc URI.
        let uri_str = match &source {
            MediaSource::Plain(uri) => uri.as_str(),
            MediaSource::Encrypted(file) => file.url.as_str(),
        };
        if !uri_str.starts_with("mxc://") {
            return Err(ParlotteError::Room {
                message: format!("invalid mxc URI: {uri_str}"),
            });
        }

        let client = self.client();
        self.runtime.block_on(async {
            let request = MediaRequestParameters {
                source,
                format: MediaFormat::File,
            };
            client
                .media()
                .get_media_content(&request, true)
                .await
                .map_err(|e| ParlotteError::Room {
                    message: format!("failed to download media: {e}"),
                })
        })
    }

    /// Get the list of members in a room.
    pub fn room_members(&self, room_id: &str) -> Result<Vec<RoomMemberInfo>> {
        use matrix_sdk::RoomMemberships;

        let client = self.client();
        self.runtime.block_on(async {
            let room_id = <&RoomId>::try_from(room_id).map_err(|e| ParlotteError::Room {
                message: format!("invalid room ID: {e}"),
            })?;

            let room = client
                .get_room(room_id)
                .ok_or_else(|| ParlotteError::Room {
                    message: format!("room {room_id} not found"),
                })?;

            let members =
                room.members(RoomMemberships::JOIN)
                    .await
                    .map_err(|e| ParlotteError::Room {
                        message: format!("failed to fetch members: {e}"),
                    })?;

            Ok(members
                .into_iter()
                .map(|m| RoomMemberInfo {
                    user_id: m.user_id().to_string(),
                    display_name: m.display_name().map(|s| s.to_owned()),
                    avatar_url: m.avatar_url().map(|u| u.to_string()),
                    power_level: match m.power_level() {
                        matrix_sdk::ruma::events::room::power_levels::UserPowerLevel::Int(n) => {
                            n.into()
                        }
                        _ => 100,
                    },
                    role: match m.suggested_role_for_power_level() {
                        matrix_sdk::room::RoomMemberRole::Administrator => "admin".to_owned(),
                        matrix_sdk::room::RoomMemberRole::Moderator => "moderator".to_owned(),
                        _ => "member".to_owned(),
                    },
                })
                .collect())
        })
    }

    /// Get the current recovery (key backup + secret storage) state.
    pub fn recovery_state(&self) -> RecoveryState {
        self.client().encryption().recovery().state().into()
    }

    /// Check whether the current session is the only device owning the
    /// cross-signing secrets. Used to warn the user before logout that
    /// they'll lose access to encrypted history if they haven't set up
    /// key backup. Returns `None` if the answer can't be determined
    /// (e.g. cross-signing isn't set up yet).
    pub fn is_last_device(&self) -> Result<Option<bool>> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .encryption()
                .recovery()
                .is_last_device()
                .await
                .map(Some)
                .or(Ok(None))
        })
    }

    /// Enable recovery: bootstraps cross-signing (if not already done),
    /// creates a server-side key backup, and a new secret storage key.
    /// Returns the base58 recovery key the user must save.
    ///
    /// If `passphrase` is provided, recovery can be unlocked with either the
    /// key or the passphrase.
    ///
    /// Bootstrapping cross-signing may require user-interactive auth (UIA).
    /// If the server demands it, this returns a `ParlotteError::Auth` error
    /// with a message describing the UIA challenge — callers should surface
    /// that and (for password logins) retry after re-entering the password.
    pub fn enable_recovery(&self, passphrase: Option<&str>) -> Result<String> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .encryption()
                .bootstrap_cross_signing(None)
                .await
                .map_err(|e| {
                    if e.as_uiaa_response().is_some() {
                        ParlotteError::Auth {
                            message: format!(
                                "server requires re-authentication to set up encryption: {e}"
                            ),
                        }
                    } else {
                        ParlotteError::Unknown {
                            message: format!("failed to bootstrap cross-signing: {e}"),
                        }
                    }
                })?;

            let recovery = client.encryption().recovery();
            let enable = if let Some(p) = passphrase {
                recovery
                    .enable()
                    .with_passphrase(p)
                    .wait_for_backups_to_upload()
            } else {
                recovery.enable().wait_for_backups_to_upload()
            };
            let key = enable.await.map_err(|e| ParlotteError::Unknown {
                message: format!("failed to enable recovery: {e}"),
            })?;

            // `enable()` can return Ok with state still Incomplete if the
            // cross-signing secrets weren't locally cached (e.g. another
            // device set them up). Treat that as a failure so the UI doesn't
            // silently claim success.
            let state: RecoveryState = recovery.state().into();
            if !matches!(state, RecoveryState::Enabled) {
                return Err(ParlotteError::Unknown {
                    message: format!(
                        "recovery enable finished but state is {state:?}. \
                         This usually means cross-signing secrets are missing \
                         from this session — sign in on a device that has them \
                         and try again, or enter the existing recovery key."
                    ),
                });
            }
            Ok(key)
        })
    }

    /// Disable recovery: tears down the server-side key backup and clears the
    /// default secret storage key.
    pub fn disable_recovery(&self) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            client
                .encryption()
                .recovery()
                .disable()
                .await
                .map_err(|e| ParlotteError::Unknown {
                    message: format!("failed to disable recovery: {e}"),
                })
        })
    }

    /// Use a recovery key (or passphrase) to import secrets into this device.
    /// Call this after logging in on a new device when `recovery_state` is
    /// `Incomplete`.
    pub fn recover(&self, recovery_key: &str) -> Result<()> {
        let client = self.client();
        self.runtime.block_on(async {
            let recovery = client.encryption().recovery();
            recovery
                .recover(recovery_key)
                .await
                .map_err(|e| ParlotteError::Auth {
                    message: format!("failed to recover: {e}"),
                })?;

            // `recover()` can return Ok after "opening" secret storage even
            // if SSSS doesn't actually contain the cross-signing secrets
            // (e.g. an earlier enable finished before cross-signing was
            // bootstrapped, leaving an empty SSSS on the server). The key
            // works, but nothing useful gets imported.
            let state: RecoveryState = recovery.state().into();
            if !matches!(state, RecoveryState::Enabled) {
                return Err(ParlotteError::Unknown {
                    message: format!(
                        "recovery key accepted but state is {state:?}. \
                         Your server-side backup is missing cross-signing \
                         secrets — this usually means a previous setup \
                         didn't complete. You'll need to reset recovery \
                         (this requires re-authenticating with your password)."
                    ),
                });
            }
            Ok(())
        })
    }

    /// Start a cross-signing identity reset (the "lost recovery key" path).
    ///
    /// Tears down the existing server-side backup + secret storage and begins
    /// the reset. If the server requires user-interactive approval, the handle
    /// is stashed on the client and this returns:
    ///
    /// - `Some(url)` for OAuth/MAS: the user must open this URL in a browser
    ///   and approve the reset, then the caller must invoke
    ///   `finish_reset_identity` to complete the exchange.
    /// - `None` if no approval was required: the reset is already complete
    ///   and a fresh recovery key was generated. The key is returned by a
    ///   follow-up call to `finish_reset_identity` (which is a no-op wait in
    ///   that case and just runs `enable_recovery`).
    ///
    /// Homeservers that only support UIAA (password re-auth) return an
    /// `Auth` error — parlotte's reset flow is MAS-shaped for now.
    pub fn begin_reset_identity(&self) -> Result<Option<String>> {
        let client = self.client();
        let active_reset = self.active_reset.clone();
        self.runtime.block_on(async move {
            let handle = client
                .encryption()
                .recovery()
                .reset_identity()
                .await
                .map_err(|e| ParlotteError::Unknown {
                    message: format!("failed to start identity reset: {e}"),
                })?;

            let Some(handle) = handle else {
                // No auth required — the SDK already cleared the old backup
                // and re-enabled key backup. Callers still need to finish
                // to generate a fresh recovery key.
                *active_reset.lock().await = None;
                return Ok(None);
            };

            let url = match handle.auth_type() {
                CrossSigningResetAuthType::OAuth(info) => info.approval_url.to_string(),
                CrossSigningResetAuthType::Uiaa(_) => {
                    handle.cancel().await;
                    return Err(ParlotteError::Auth {
                        message: "this homeserver requires password re-authentication \
                                  to reset encryption; parlotte only supports the \
                                  OAuth (MAS) reset flow right now"
                            .to_owned(),
                    });
                }
            };

            *active_reset.lock().await = Some(handle);
            Ok(Some(url))
        })
    }

    /// Finish a reset started by `begin_reset_identity`.
    ///
    /// For the OAuth path this blocks until the user has approved the reset
    /// in their browser — the SDK polls the upload request until the server
    /// stops returning UIAA errors. After the cross-signing identity is
    /// uploaded, a fresh recovery key is generated and returned.
    ///
    /// Returns an error if no reset was started.
    pub fn finish_reset_identity(&self) -> Result<String> {
        let client = self.client();
        let active_reset = self.active_reset.clone();
        self.runtime.block_on(async move {
            // Take the handle out of the mutex in its own scope so the guard is
            // dropped before the (potentially minutes-long) `reset(..)` await.
            // Holding it across the await would block `cancel_reset_identity`
            // from ever acquiring the lock to cancel.
            let handle = { active_reset.lock().await.take() };
            if let Some(handle) = handle {
                handle.reset(None).await.map_err(|e| ParlotteError::Auth {
                    message: format!("identity reset failed: {e}"),
                })?;
            }

            // Reset succeeded (or wasn't needed). Generate a fresh recovery
            // key so the user walks away with something they can actually
            // use on a new device.
            let recovery = client.encryption().recovery();
            let key = recovery
                .enable()
                .wait_for_backups_to_upload()
                .await
                .map_err(|e| ParlotteError::Unknown {
                    message: format!(
                        "identity reset succeeded but failed to enable fresh \
                         recovery: {e}"
                    ),
                })?;

            let state: RecoveryState = recovery.state().into();
            if !matches!(state, RecoveryState::Enabled) {
                return Err(ParlotteError::Unknown {
                    message: format!(
                        "identity reset finished but recovery state is {state:?} \
                         — the fresh backup didn't come up; try enabling \
                         recovery again."
                    ),
                });
            }
            Ok(key)
        })
    }

    /// Cancel an in-progress reset started by `begin_reset_identity`.
    /// Safe to call when no reset is in progress.
    pub fn cancel_reset_identity(&self) {
        let active_reset = self.active_reset.clone();
        self.runtime.block_on(async move {
            if let Some(handle) = active_reset.lock().await.take() {
                handle.cancel().await;
            }
        });
    }

    // ---------- Device verification (cross-signing / SAS) ----------

    /// Register a listener and event handler for incoming verification
    /// requests. Must be called once after login/restore; safe to call again
    /// to replace the listener.
    pub fn set_verification_listener(&self, listener: Arc<dyn VerificationListener>) {
        use matrix_sdk::ruma::events::key::verification::request::ToDeviceKeyVerificationRequestEvent;

        let client = self.client().clone();
        let active = self.active_verification.clone();
        let listener_for_handler = listener.clone();

        let handle = self.runtime.block_on(async move {
            client.add_event_handler(
                move |event: ToDeviceKeyVerificationRequestEvent, client: matrix_sdk::Client| {
                    let listener = listener_for_handler.clone();
                    let active = active.clone();
                    async move {
                        let flow_id = event.content.transaction_id.to_string();
                        let sender = event.sender;
                        let request = client
                            .encryption()
                            .get_verification_request(&sender, &flow_id)
                            .await;
                        if let Some(request) = request {
                            let info = verification::request_info(&request);
                            {
                                let mut guard = active.lock().await;
                                guard.request = Some(request);
                                guard.sas = None;
                            }
                            listener.on_verification_request(info);
                        } else {
                            tracing::warn!(
                                "received verification request event but get_verification_request returned None (flow_id={flow_id})"
                            );
                        }
                    }
                },
            )
        });

        // Remove a previously-registered handler so re-registration replaces
        // it rather than stacking duplicate handlers (each would fire its own
        // callback and pin an old listener object alive).
        if let Some(previous) = self.verification_handle.lock().unwrap().replace(handle) {
            self.client().remove_event_handler(previous);
        }
    }

    /// Start a self-verification flow: send a verification request to all our
    /// other devices. Returns the `VerificationRequestInfo`.
    pub fn request_self_verification(&self) -> Result<VerificationRequestInfo> {
        let client = self.client();
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let user_id = client.user_id().ok_or_else(|| ParlotteError::Auth {
                message: "not logged in".to_string(),
            })?;

            // On a fresh account cross-signing may not be bootstrapped yet.
            // Try to bootstrap without auth data first — this works on servers
            // that don't require UIAA for this endpoint (e.g. test instances,
            // or a fresh session within its grace window).
            client
                .encryption()
                .bootstrap_cross_signing_if_needed(None)
                .await
                .map_err(|e| ParlotteError::Unknown {
                    message: format!(
                        "could not bootstrap cross-signing: {e}. \
                         Enable encrypted backup first to set up cross-signing \
                         with your password."
                    ),
                })?;

            let identity = client
                .encryption()
                .get_user_identity(user_id)
                .await
                .map_err(|e| ParlotteError::Unknown {
                    message: format!("failed to fetch user identity: {e}"),
                })?
                .ok_or_else(|| ParlotteError::Unknown {
                    message: "own user identity unavailable after bootstrap".to_string(),
                })?;
            let request =
                identity
                    .request_verification()
                    .await
                    .map_err(|e| ParlotteError::Unknown {
                        message: format!("failed to request verification: {e}"),
                    })?;
            let info = verification::request_info(&request);
            let mut guard = active.lock().await;
            guard.request = Some(request);
            guard.sas = None;
            Ok(info)
        })
    }

    /// Accept an incoming verification request (receiver side).
    pub fn accept_verification(&self) -> Result<()> {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let guard = active.lock().await;
            let request = guard
                .request
                .as_ref()
                .ok_or_else(|| ParlotteError::Unknown {
                    message: "no active verification to accept".to_string(),
                })?;
            request.accept().await.map_err(|e| ParlotteError::Unknown {
                message: format!("failed to accept verification: {e}"),
            })
        })
    }

    /// Transition the active verification into a SAS (emoji) flow.
    pub fn start_sas_verification(&self) -> Result<()> {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let sas_opt = {
                let guard = active.lock().await;
                let request = guard
                    .request
                    .as_ref()
                    .ok_or_else(|| ParlotteError::Unknown {
                        message: "no active verification".to_string(),
                    })?;
                request
                    .start_sas()
                    .await
                    .map_err(|e| ParlotteError::Unknown {
                        message: format!("failed to start SAS: {e}"),
                    })?
            };
            let mut guard = active.lock().await;
            guard.sas = sas_opt;
            Ok(())
        })
    }

    /// Confirm the SAS emojis matched. Completes the verification on our side.
    pub fn confirm_sas_verification(&self) -> Result<()> {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let guard = active.lock().await;
            let sas = guard.sas.as_ref().ok_or_else(|| ParlotteError::Unknown {
                message: "no SAS verification in progress".to_string(),
            })?;
            sas.confirm().await.map_err(|e| ParlotteError::Unknown {
                message: format!("failed to confirm SAS: {e}"),
            })
        })
    }

    /// Signal that the emojis did not match; cancels the verification.
    pub fn sas_mismatch(&self) -> Result<()> {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let guard = active.lock().await;
            let sas = guard.sas.as_ref().ok_or_else(|| ParlotteError::Unknown {
                message: "no SAS verification in progress".to_string(),
            })?;
            sas.mismatch().await.map_err(|e| ParlotteError::Unknown {
                message: format!("failed to signal mismatch: {e}"),
            })
        })
    }

    /// Cancel the active verification request (or SAS if one was started).
    pub fn cancel_verification(&self) -> Result<()> {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let guard = active.lock().await;
            if let Some(sas) = guard.sas.as_ref() {
                sas.cancel().await.map_err(|e| ParlotteError::Unknown {
                    message: format!("failed to cancel SAS: {e}"),
                })?;
            } else if let Some(request) = guard.request.as_ref() {
                request.cancel().await.map_err(|e| ParlotteError::Unknown {
                    message: format!("failed to cancel verification: {e}"),
                })?;
            }
            Ok(())
        })
    }

    /// Refresh the active verification's SAS handle from the request's
    /// transitioned state (call after each sync tick to surface emoji state).
    /// If the SAS was started by the other side (receiver flow), auto-accept
    /// it so the key-exchange can proceed.
    fn refresh_sas_from_request(&self) {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let sas_to_accept = {
                let mut guard = active.lock().await;
                if guard.sas.is_some() {
                    None
                } else if let Some(request) = guard.request.as_ref() {
                    if let SdkRequestState::Transitioned { verification } = request.state() {
                        if let Some(sas) = verification.sas() {
                            guard.sas = Some(sas.clone());
                            if !sas.we_started() {
                                Some(sas)
                            } else {
                                None
                            }
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                } else {
                    None
                }
            };

            if let Some(sas) = sas_to_accept {
                if let Err(e) = sas.accept().await {
                    tracing::warn!("failed to auto-accept SAS on receiver: {e}");
                }
            }
        });
    }

    /// Get the current state of the active verification, or `None` if there
    /// isn't one.
    pub fn verification_state(&self) -> Option<VerificationState> {
        // Opportunistically pick up a SAS that was created by the other side.
        self.refresh_sas_from_request();
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let guard = active.lock().await;
            guard.request.as_ref()?;
            verification::derive_state(&guard).ok()
        })
    }

    /// Clear the active verification (after completion / cancellation /
    /// dismissal from the UI).
    pub fn clear_verification(&self) {
        let active = self.active_verification.clone();
        self.runtime.block_on(async {
            let mut guard = active.lock().await;
            guard.request = None;
            guard.sas = None;
        });
    }
}

/// Extract the plain-text body and optional HTML formatted body from a message type.
/// A single `m.replace` (edit) event collected while scanning a batch.
struct EditCandidate {
    body: String,
    formatted_body: Option<String>,
    sender: String,
}

/// Apply aggregated edits to their target messages. Per the Matrix spec an
/// edit is only valid when its sender matches the original event's sender —
/// servers do not filter cross-sender replacements out of `/messages`, so
/// skipping this check lets any room member rewrite anyone's message.
/// Candidates are newest-first; the first valid one per target wins, so a
/// spoofed newer "edit" can't shadow a legitimate older one.
fn apply_edits(messages: &mut [MessageInfo], mut edits: HashMap<String, Vec<EditCandidate>>) {
    for msg in messages.iter_mut() {
        let Some(candidates) = edits.remove(&msg.event_id) else {
            continue;
        };
        if let Some(edit) = candidates.into_iter().find(|e| e.sender == msg.sender) {
            msg.body = edit.body;
            msg.formatted_body = edit.formatted_body;
            msg.is_edited = true;
        }
    }
}

fn extract_body_and_formatted(
    msgtype: &matrix_sdk::ruma::events::room::message::MessageType,
) -> (String, Option<String>) {
    use matrix_sdk::ruma::events::room::message::MessageType;

    match msgtype {
        MessageType::Text(text) => {
            let formatted = text
                .formatted
                .as_ref()
                .filter(|f| {
                    f.format == matrix_sdk::ruma::events::room::message::MessageFormat::Html
                })
                .map(|f| f.body.clone());
            (text.body.clone(), formatted)
        }
        MessageType::Notice(notice) => {
            let formatted = notice
                .formatted
                .as_ref()
                .filter(|f| {
                    f.format == matrix_sdk::ruma::events::room::message::MessageFormat::Html
                })
                .map(|f| f.body.clone());
            (notice.body.clone(), formatted)
        }
        MessageType::Emote(emote) => {
            let formatted = emote
                .formatted
                .as_ref()
                .filter(|f| {
                    f.format == matrix_sdk::ruma::events::room::message::MessageFormat::Html
                })
                .map(|f| f.body.clone());
            (emote.body.clone(), formatted)
        }
        MessageType::Image(img) => (img.body.clone(), None),
        MessageType::File(file) => (file.body.clone(), None),
        MessageType::Video(video) => (video.body.clone(), None),
        MessageType::Audio(audio) => (audio.body.clone(), None),
        MessageType::Location(loc) => (loc.body.clone(), None),
        _ => ("[unsupported message]".to_owned(), None),
    }
}

/// Media metadata extracted from a message content.
///
/// Returns (source mxc URI, mime type, width, height, size). All fields are
/// `None` for non-media message types (text, notice, emote, location).
type MediaFields = (
    Option<String>,
    Option<String>,
    Option<u32>,
    Option<u32>,
    Option<u64>,
);

fn extract_media_info(
    msgtype: &matrix_sdk::ruma::events::room::message::MessageType,
) -> MediaFields {
    use matrix_sdk::ruma::events::room::message::MessageType;
    use matrix_sdk::ruma::events::room::MediaSource;

    // Serialize the full MediaSource (including encryption keys for E2EE rooms)
    // so that download_media can reconstruct the correct variant for decryption.
    let serialize_source = |source: &MediaSource| -> String {
        serde_json::to_string(source).unwrap_or_else(|_| match source {
            MediaSource::Plain(uri) => uri.to_string(),
            MediaSource::Encrypted(file) => file.url.to_string(),
        })
    };

    match msgtype {
        MessageType::Image(img) => {
            let source = Some(serialize_source(&img.source));
            let (mime, w, h, size) = img
                .info
                .as_ref()
                .map(|i| {
                    (
                        i.mimetype.clone(),
                        i.width.map(|v| u64::from(v) as u32),
                        i.height.map(|v| u64::from(v) as u32),
                        i.size.map(u64::from),
                    )
                })
                .unwrap_or((None, None, None, None));
            (source, mime, w, h, size)
        }
        MessageType::File(file) => {
            let source = Some(serialize_source(&file.source));
            let (mime, size) = file
                .info
                .as_ref()
                .map(|i| (i.mimetype.clone(), i.size.map(u64::from)))
                .unwrap_or((None, None));
            (source, mime, None, None, size)
        }
        MessageType::Video(video) => {
            let source = Some(serialize_source(&video.source));
            let (mime, w, h, size) = video
                .info
                .as_ref()
                .map(|i| {
                    (
                        i.mimetype.clone(),
                        i.width.map(|v| u64::from(v) as u32),
                        i.height.map(|v| u64::from(v) as u32),
                        i.size.map(u64::from),
                    )
                })
                .unwrap_or((None, None, None, None));
            (source, mime, w, h, size)
        }
        MessageType::Audio(audio) => {
            let source = Some(serialize_source(&audio.source));
            let (mime, size) = audio
                .info
                .as_ref()
                .map(|i| (i.mimetype.clone(), i.size.map(u64::from)))
                .unwrap_or((None, None));
            (source, mime, None, None, size)
        }
        _ => (None, None, None, None, None),
    }
}

/// Return a short string label for the message type.
fn message_type_str(
    msgtype: &matrix_sdk::ruma::events::room::message::MessageType,
) -> &'static str {
    use matrix_sdk::ruma::events::room::message::MessageType;

    match msgtype {
        MessageType::Text(_) => "text",
        MessageType::Notice(_) => "notice",
        MessageType::Emote(_) => "emote",
        MessageType::Image(_) => "image",
        MessageType::File(_) => "file",
        MessageType::Video(_) => "video",
        MessageType::Audio(_) => "audio",
        MessageType::Location(_) => "location",
        _ => "unknown",
    }
}

fn build_client_metadata(redirect_uri: url::Url) -> Result<ClientMetadata> {
    let client_uri =
        url::Url::parse("https://nxthdr.github.io/parlotte/").map_err(|e| ParlotteError::Auth {
            message: format!("invalid client URI: {e}"),
        })?;

    let mut metadata = ClientMetadata::new(
        ApplicationType::Native,
        vec![OAuthGrantType::AuthorizationCode {
            redirect_uris: vec![redirect_uri],
        }],
        Localized::new(client_uri, []),
    );
    metadata.client_name = Some(Localized::new("Parlotte".to_owned(), []));
    Ok(metadata)
}

impl Drop for ParlotteClient {
    fn drop(&mut self) {
        // Drop the inner Client inside the tokio runtime so that deadpool's
        // SQLite connection pool cleanup has access to a reactor.
        if let Some(client) = self.inner.take() {
            self.runtime.block_on(async move {
                drop(client);
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- Tests for our input validation and error mapping --

    #[test]
    fn client_creation_with_no_store() {
        // Our code should build a client successfully when given a valid URL
        // and no store path (in-memory mode).
        let client = ParlotteClient::new("http://localhost:1234", None);
        assert!(client.is_ok());
    }

    #[test]
    fn client_creation_with_invalid_url() {
        // Our code maps SDK builder errors into ParlotteError::Network
        let result = ParlotteClient::new("not-a-valid-url", None);
        match result {
            Err(ParlotteError::Network { .. }) => {} // expected
            Err(other) => panic!("expected Network error, got: {other}"),
            Ok(_) => panic!("expected error for invalid URL"),
        }
    }

    #[test]
    fn send_message_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_message("not-a-room-id", "hello");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("invalid room ID"));
    }

    #[test]
    fn messages_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.messages("not-a-room-id", 50, None);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn messages_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.messages("!nonexistent:example.com", 50, None);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn send_message_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        // Valid format but room doesn't exist in client state
        let result = client.send_message("!nonexistent:example.com", "hello");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn send_reply_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_reply("not-a-room-id", "$event:example.com", "reply");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("invalid room ID"));
    }

    #[test]
    fn send_reply_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_reply("!nonexistent:example.com", "$event:example.com", "reply");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn invite_user_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.invite_user("bad-room", "@alice:example.com");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn invite_user_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.invite_user("!room:example.com", "not-a-user-id");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("invalid user ID"));
    }

    #[test]
    fn join_room_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.join_room("garbage");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn leave_room_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.leave_room("garbage");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn leave_room_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.leave_room("!nonexistent:example.com");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn set_room_name_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_room_name("garbage", "New Name");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn set_room_name_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_room_name("!nonexistent:example.com", "New Name");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn set_room_topic_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_room_topic("garbage", "New topic");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn set_room_topic_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_room_topic("!nonexistent:example.com", "Topic");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn room_members_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.room_members("garbage");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn set_user_power_level_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_user_power_level("garbage", "@a:x.com", 50);
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn set_user_power_level_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_user_power_level("!room:example.com", "not-a-user", 50);
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("invalid user ID"));
    }

    #[test]
    fn kick_user_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.kick_user("garbage", "@a:x.com", None);
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn kick_user_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.kick_user("!room:example.com", "nope", Some("spam".into()));
        let err = result.unwrap_err();
        assert!(err.to_string().contains("invalid user ID"));
    }

    #[test]
    fn ban_user_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.ban_user("garbage", "@a:x.com", None);
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn unban_user_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.unban_user("!room:example.com", "nope", None);
        let err = result.unwrap_err();
        assert!(err.to_string().contains("invalid user ID"));
    }

    fn make_message(event_id: &str, sender: &str, body: &str) -> MessageInfo {
        MessageInfo {
            event_id: event_id.into(),
            sender: sender.into(),
            body: body.into(),
            formatted_body: None,
            message_type: "text".into(),
            timestamp_ms: 0,
            is_edited: false,
            replied_to_event_id: None,
            media_source: None,
            media_mime_type: None,
            media_width: None,
            media_height: None,
            media_size: None,
            reactions: vec![],
        }
    }

    fn make_edit(sender: &str, body: &str) -> EditCandidate {
        EditCandidate {
            body: body.into(),
            formatted_body: None,
            sender: sender.into(),
        }
    }

    #[test]
    fn apply_edits_same_sender_applies() {
        let mut messages = vec![make_message("$1", "@alice:x.com", "original")];
        let mut edits = HashMap::new();
        edits.insert("$1".to_string(), vec![make_edit("@alice:x.com", "edited")]);
        apply_edits(&mut messages, edits);
        assert_eq!(messages[0].body, "edited");
        assert!(messages[0].is_edited);
    }

    #[test]
    fn apply_edits_rejects_cross_sender_spoof() {
        let mut messages = vec![make_message("$1", "@alice:x.com", "original")];
        let mut edits = HashMap::new();
        edits.insert(
            "$1".to_string(),
            vec![make_edit("@mallory:evil.com", "spoofed")],
        );
        apply_edits(&mut messages, edits);
        assert_eq!(messages[0].body, "original");
        assert!(!messages[0].is_edited);
    }

    #[test]
    fn apply_edits_newest_edit_wins() {
        let mut messages = vec![make_message("$1", "@alice:x.com", "original")];
        let mut edits = HashMap::new();
        // Candidates are collected newest-first from the batch.
        edits.insert(
            "$1".to_string(),
            vec![
                make_edit("@alice:x.com", "second edit"),
                make_edit("@alice:x.com", "first edit"),
            ],
        );
        apply_edits(&mut messages, edits);
        assert_eq!(messages[0].body, "second edit");
    }

    #[test]
    fn apply_edits_spoofed_newest_does_not_shadow_legit_older() {
        let mut messages = vec![make_message("$1", "@alice:x.com", "original")];
        let mut edits = HashMap::new();
        edits.insert(
            "$1".to_string(),
            vec![
                make_edit("@mallory:evil.com", "spoofed"),
                make_edit("@alice:x.com", "legit edit"),
            ],
        );
        apply_edits(&mut messages, edits);
        assert_eq!(messages[0].body, "legit edit");
        assert!(messages[0].is_edited);
    }

    #[test]
    fn ignore_user_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.ignore_user("not-a-user");
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Unknown { .. }));
        assert!(err.to_string().contains("invalid user ID"));
    }

    #[test]
    fn unignore_user_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.unignore_user("nope");
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Unknown { .. }));
        assert!(err.to_string().contains("invalid user ID"));
    }

    #[test]
    fn ignored_users_empty_before_login() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.ignored_users().unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn room_members_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.room_members("!nonexistent:example.com");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn send_read_receipt_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_read_receipt("garbage", "$event:example.com");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn send_read_receipt_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_read_receipt("!room:example.com", "$event:example.com");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn send_typing_notice_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_typing_notice("not-a-room-id", true);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn send_typing_notice_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_typing_notice("!nonexistent:example.com", true);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn send_attachment_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_attachment(
            "garbage",
            "file.png",
            "image/png",
            vec![1, 2, 3],
            Some(10),
            Some(10),
        );
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn send_attachment_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_attachment(
            "!nonexistent:example.com",
            "file.png",
            "image/png",
            vec![1, 2, 3],
            None,
            None,
        );
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ParlotteError::Room { .. }));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn send_attachment_rejects_invalid_mime() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_attachment(
            "!room:example.com",
            "file.png",
            "not a valid mime type",
            vec![1, 2, 3],
            None,
            None,
        );
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("invalid MIME type"));
    }

    #[test]
    fn download_media_rejects_invalid_mxc_uri() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.download_media("not-a-valid-mxc-uri");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn edit_message_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.edit_message("garbage", "$event:example.com", "new body");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn edit_message_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.edit_message("!room:example.com", "$event:example.com", "new body");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn redact_message_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.redact_message("garbage", "$event:example.com");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn redact_message_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.redact_message("!room:example.com", "$event:example.com");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn sso_login_url_rejects_invalid_redirect() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        // This will fail because the server isn't reachable, not because of validation
        let result = client.sso_login_url("http://localhost:9999/callback", None);
        assert!(result.is_err());
    }

    #[test]
    fn login_sso_callback_rejects_invalid_url() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.login_sso_callback("not-a-url");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Auth { .. }));
    }

    #[test]
    fn login_sso_callback_rejects_missing_token() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.login_sso_callback("http://localhost:9999/callback?notoken=here");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Auth { .. }));
    }

    #[test]
    fn rooms_returns_empty_before_sync() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let rooms = client.rooms().unwrap();
        assert!(rooms.is_empty());
    }

    #[test]
    fn is_syncing_returns_false_initially() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        assert!(!client.is_syncing());
    }

    #[test]
    fn session_returns_none_before_login() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        assert!(client.session().is_none());
    }

    #[test]
    fn restore_session_rejects_invalid_user_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let data = MatrixSessionData {
            user_id: "not-a-valid-user-id".into(),
            device_id: "SOMEDEVICE".into(),
            access_token: "some_token".into(),
        };
        let result = client.restore_session(data);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Auth { .. }));
    }

    #[test]
    fn send_reaction_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_reaction("bad-room", "$event:example.com", "👍");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn send_reaction_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.send_reaction("!room:example.com", "$event:example.com", "👍");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn send_reaction_rejects_invalid_event_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        // A syntactically valid room ID with a bad event ID must fail
        // specifically on the event ID — input is validated before the room
        // lookup, so this no longer passes merely because the room is absent.
        let result = client.send_reaction("!room:example.com", "bad-event", "👍");
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("invalid event ID"),
            "expected invalid event ID error, got: {err_msg}"
        );
    }

    #[test]
    fn redact_reaction_rejects_invalid_room_id() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.redact_reaction("bad-room", "$reaction:example.com");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ParlotteError::Room { .. }));
    }

    #[test]
    fn redact_reaction_rejects_nonexistent_room() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.redact_reaction("!room:example.com", "$reaction:example.com");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn set_avatar_rejects_invalid_mime() {
        let client = ParlotteClient::new("http://localhost:1234", None).unwrap();
        let result = client.set_avatar("not a valid mime", vec![1, 2, 3]);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("invalid MIME type"));
    }

    // Note: SQLite store path testing is covered in integration tests because
    // the deadpool connection pool has tokio runtime lifecycle requirements
    // that conflict with ParlotteClient's embedded runtime in unit test context.
}
