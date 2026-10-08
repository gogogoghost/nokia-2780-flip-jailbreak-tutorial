/// Implementation of the screencapture service.
///
/// Every method is gated twice: the daemon refuses to create the service at all
/// unless the caller token carries the `screencapture` permission (generated
/// `check_service_permission`), and each method re-checks it here.
///
/// The recording itself lives in the shared state, which `shared_state()` hands
/// out once per child daemon process, so every client session of this daemon
/// looks at the same recording — and the recording outlives the page that
/// started it.
///
/// This crate is built against the api-daemon revision matching the device
/// firmware (KaiOS 3.1): responders are `&Responder` and are not `Send`, so the
/// backend calls run inline on the child IPC thread, like the other services of
/// that revision.
use crate::backend::{Recorder, KCAP};
use crate::generated::common::*;
use crate::generated::service::*;
use common::core::BaseMessage;
use common::traits::{
    CommonResponder, OriginAttributes, Service, SessionSupport, Shared, SharedSessionContext,
    StateLogger, TrackerId,
};
use log::{error, info};

/// Permission required to create the service and to call any of its methods.
pub const PERMISSION: &str = "screencapture";

impl StateLogger for Recorder {}

pub struct ScreencaptureImpl {
    id: TrackerId,
    origin_attributes: OriginAttributes,
    recorder: Shared<Recorder>,
}

impl Screencapture for ScreencaptureImpl {}

impl ScreencaptureFactoryMethods for ScreencaptureImpl {
    fn record(&mut self, responder: &ScreencaptureFactoryRecordResponder, bitrate: i64) {
        if responder.maybe_send_permission_error(
            &self.origin_attributes,
            PERMISSION,
            "record the screen",
        ) {
            return;
        }

        let mut recorder = self.recorder.lock();
        match recorder.start(bitrate) {
            Ok(()) => {
                info!("recording at {} bit/s with {}", bitrate, KCAP);
                responder.resolve(true)
            }
            Err(err) => responder.reject(err),
        }
    }

    fn stop(&mut self, responder: &ScreencaptureFactoryStopResponder) {
        if responder.maybe_send_permission_error(
            &self.origin_attributes,
            PERMISSION,
            "stop recording",
        ) {
            return;
        }

        let mut recorder = self.recorder.lock();
        match recorder.stop() {
            Ok(()) => responder.resolve(true),
            Err(err) => responder.reject(err),
        }
    }

    fn is_recording(&mut self, responder: &ScreencaptureFactoryIsRecordingResponder) {
        if responder.maybe_send_permission_error(
            &self.origin_attributes,
            PERMISSION,
            "check the recording",
        ) {
            return;
        }

        let recording = self.recorder.lock().is_recording();
        responder.resolve(recording)
    }

    fn elapsed(&mut self, responder: &ScreencaptureFactoryElapsedResponder) {
        if responder.maybe_send_permission_error(
            &self.origin_attributes,
            PERMISSION,
            "check the recording",
        ) {
            return;
        }

        let elapsed = self.recorder.lock().elapsed();
        responder.resolve(elapsed)
    }

    fn get_blob(&mut self, responder: &ScreencaptureFactoryGetBlobResponder) {
        if responder.maybe_send_permission_error(
            &self.origin_attributes,
            PERMISSION,
            "read the recording",
        ) {
            return;
        }

        let mut recorder = self.recorder.lock();
        match recorder.take_blob() {
            Ok(blob) => {
                info!("returning {} bytes of recording", blob.len());
                responder.resolve(blob)
            }
            Err(err) => responder.reject(err),
        }
    }
}

impl Service<ScreencaptureImpl> for ScreencaptureImpl {
    // Shared by every instance, i.e. by every client of this daemon.
    type State = Recorder;

    fn shared_state() -> Shared<Self::State> {
        Shared::adopt(Recorder::new())
    }

    fn create(
        origin_attributes: &OriginAttributes,
        _context: SharedSessionContext,
        state: Shared<Self::State>,
        helper: SessionSupport,
    ) -> Result<ScreencaptureImpl, String> {
        info!("screencapture::create for {}", origin_attributes.identity());

        Ok(ScreencaptureImpl {
            id: helper.session_tracker_id().service(),
            origin_attributes: origin_attributes.clone(),
            recorder: state,
        })
    }

    /// Returns a human readable version of the request.
    fn format_request(&mut self, _transport: &SessionSupport, message: &BaseMessage) -> String {
        let req: Result<ScreencaptureFromClient, common::BincodeError> =
            common::deserialize_bincode(&message.content);
        match req {
            Ok(req) => format!("screencapture request: {:?}", req),
            Err(err) => format!("Unable to format screencapture request: {:?}", err),
        }
    }

    /// Processes a request coming from the Session.
    fn on_request(&mut self, transport: &SessionSupport, message: &BaseMessage) {
        self.dispatch_request(transport, message);
    }

    fn release_object(&mut self, object_id: u32) -> bool {
        error!("Releasing object {} in screencapture service", object_id);
        false
    }
}

impl Drop for ScreencaptureImpl {
    // The recording deliberately keeps running: it belongs to the daemon, not to
    // this session, so an application going away does not stop it.
    fn drop(&mut self) {
        info!("Dropping screencapture Service #{}", self.id);
    }
}
