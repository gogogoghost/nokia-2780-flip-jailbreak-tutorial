/// Implementation of the Sideload service.
///
/// Every method is gated twice: the daemon refuses to create the service at all
/// unless the caller token carries the `sideload` permission (generated
/// `check_service_permission`), and each method re-checks it here.
///
/// Backends (see `backend.rs`): app management is forwarded to the api-daemon
/// apps service UDS, installed app files are read from the api-daemon vhost.
///
/// This crate is built against the api-daemon revision matching the device
/// firmware (KaiOS 3.1): responders are `&Responder` and are not `Send`, so the
/// backend calls run inline on the child IPC thread, like the other services of
/// that revision.
use crate::backend;
use crate::generated::common::*;
use crate::generated::service::*;
use common::core::BaseMessage;
use common::traits::{
    CommonResponder, OriginAttributes, Service, SessionSupport, Shared, SharedSessionContext,
    TrackerId,
};
use common::JsonValue;
use log::{error, info};

/// Permission required to create the service and to call any of its methods.
pub const PERMISSION: &str = "sideload";

pub struct SideloadImpl {
    id: TrackerId,
    origin_attributes: OriginAttributes,
}

impl Sideload for SideloadImpl {}

impl SideloadFactoryMethods for SideloadImpl {
    fn list(&mut self, responder: &SideloadFactoryListResponder) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "list apps") {
            return;
        }

        match backend::apps_uds_call("list", None) {
            Ok(success) => match serde_json::from_str::<serde_json::Value>(&success) {
                Ok(value) => responder.resolve(JsonValue::from(value)),
                Err(err) => responder.reject(format!("invalid apps list payload: {}", err)),
            },
            Err(err) => responder.reject(err),
        }
    }

    fn install(&mut self, responder: &SideloadFactoryInstallResponder, package_path: String) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "install an app")
        {
            return;
        }

        match backend::apps_uds_call("install", Some(package_path.as_str())) {
            Ok(success) => responder.resolve(success),
            Err(err) => responder.reject(err),
        }
    }

    fn install_pwa(&mut self, responder: &SideloadFactoryInstallPwaResponder, manifest_url: String) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "install a pwa")
        {
            return;
        }

        match backend::apps_uds_call("install-pwa", Some(manifest_url.as_str())) {
            Ok(success) => responder.resolve(success),
            Err(err) => responder.reject(err),
        }
    }

    fn uninstall(&mut self, responder: &SideloadFactoryUninstallResponder, manifest_url: String) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "uninstall an app")
        {
            return;
        }

        match backend::apps_uds_call("uninstall", Some(manifest_url.as_str())) {
            Ok(success) => responder.resolve(success),
            Err(err) => responder.reject(err),
        }
    }

    fn get_app_file(
        &mut self,
        responder: &SideloadFactoryGetAppFileResponder,
        origin: String,
        path: String,
    ) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "read an app file")
        {
            return;
        }

        match backend::vhost_get(origin.as_str(), path.as_str()) {
            Ok(bytes) => responder.resolve(bytes),
            Err(err) => responder.reject(err),
        }
    }

    fn get_app_manifest(
        &mut self,
        responder: &SideloadFactoryGetAppManifestResponder,
        manifest_url: String,
    ) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "read an app manifest")
        {
            return;
        }

        match backend::vhost_get_manifest(manifest_url.as_str()) {
            Ok(value) => responder.resolve(JsonValue::from(value)),
            Err(err) => responder.reject(err),
        }
    }

    fn ready(&mut self, responder: &SideloadFactoryReadyResponder) {
        if responder.maybe_send_permission_error(&self.origin_attributes, PERMISSION, "check the backend")
        {
            return;
        }

        responder.resolve(backend::apps_uds_call("ready", None).is_ok())
    }
}

impl Service<SideloadImpl> for SideloadImpl {
    type State = ();

    fn shared_state() -> Shared<Self::State> {
        Shared::adopt(())
    }

    fn create(
        origin_attributes: &OriginAttributes,
        _context: SharedSessionContext,
        _state: Shared<Self::State>,
        helper: SessionSupport,
    ) -> Result<SideloadImpl, String> {
        info!("Sideload::create for {}", origin_attributes.identity());

        Ok(SideloadImpl {
            id: helper.session_tracker_id().service(),
            origin_attributes: origin_attributes.clone(),
        })
    }

    /// Returns a human readable version of the request.
    fn format_request(&mut self, _transport: &SessionSupport, message: &BaseMessage) -> String {
        let req: Result<SideloadFromClient, common::BincodeError> =
            common::deserialize_bincode(&message.content);
        match req {
            Ok(req) => format!("Sideload request: {:?}", req),
            Err(err) => format!("Unable to format Sideload request: {:?}", err),
        }
    }

    /// Processes a request coming from the Session.
    fn on_request(&mut self, transport: &SessionSupport, message: &BaseMessage) {
        self.dispatch_request(transport, message);
    }

    fn release_object(&mut self, object_id: u32) -> bool {
        error!("Releasing object {} in Sideload service", object_id);
        false
    }
}

impl Drop for SideloadImpl {
    fn drop(&mut self) {
        info!("Dropping Sideload Service #{}", self.id);
    }
}
