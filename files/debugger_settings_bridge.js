"use strict";

(function(exports) {
  const modeSetting = "debugger.remote-mode";
  const usbDevtoolsSetting = "devtools.remote.usb.enabled";

  function applyDebuggerMode(mode) {
    const enabled = mode === "adb-devtools";
    SettingsObserver.setValue([{ name: usbDevtoolsSetting, value: enabled }]);
  }

  exports.DebuggerSettingsBridge = {
    start() {
      SettingsObserver.observe(modeSetting, "disabled", applyDebuggerMode, true);
    },
  };

  exports.DebuggerSettingsBridge.start();
})(window);
