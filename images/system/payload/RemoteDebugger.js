"use strict";

XPCOMUtils.defineLazyGetter(this, "require", () => {
  let { require } = ChromeUtils.import("resource://devtools/shared/Loader.jsm");
  return require;
});

XPCOMUtils.defineLazyGetter(this, "DevToolsServer", () => {
  let { DevToolsServer } = require("devtools/server/devtools-server");
  return DevToolsServer;
});

XPCOMUtils.defineLazyGetter(this, "SocketListener", () => {
  let { SocketListener } = require("devtools/shared/security/socket");
  return SocketListener;
});

var RemoteDebugger = {
  init(aWindow) {
    this._windowType = "navigator:browser";
    USBRemoteDebugger.init();
    WiFiRemoteDebugger.init();

    const listener = event => {
      if (event.target !== aWindow) {
        return;
      }
      if (this.isAnyEnabled) {
        this.initServer();
      }
    };

    aWindow.addEventListener("activate", listener, { mozSystemGroup: true });
    aWindow.addEventListener("deactivate", listener, { mozSystemGroup: true });
  },

  get isAnyEnabled() {
    return USBRemoteDebugger.isEnabled || WiFiRemoteDebugger.isEnabled;
  },

  allowConnection(session) {
    if (this._promptingForAllow) {
      return DevToolsServer.AuthenticationResult.DENY;
    }

    if (!session.server.port) {
      this._promptingForAllow = this._promptForUSB(session);
    } else {
      this._promptingForAllow = this._promptForTCP(session);
    }

    this._promptingForAllow.then(() => (this._promptingForAllow = null));
    return this._promptingForAllow;
  },

  _promptForUSB(session) {
    if (session.authentication !== "PROMPT") {
      return DevToolsServer.AuthenticationResult.DENY;
    }

    return new Promise(resolve => {
      let title = Strings.browser.GetStringFromName("remoteIncomingPromptTitle");
      let msg = Strings.browser.GetStringFromName("remoteIncomingPromptUSB");
      let allow = Strings.browser.GetStringFromName("remoteIncomingPromptAllow");
      let deny = Strings.browser.GetStringFromName("remoteIncomingPromptDeny");
      let prompt = new Prompt({
        window: null,
        hint: "remotedebug",
        title,
        message: msg,
        buttons: [allow, deny],
        priority: 1,
      });
      prompt.show(data => {
        resolve(data.button === 0 ? DevToolsServer.AuthenticationResult.ALLOW : DevToolsServer.AuthenticationResult.DENY);
      });
    });
  },

  _promptForTCP(session) {
    let title = Strings.browser.GetStringFromName("remoteIncomingPromptTitle");
    let msg = Strings.browser.formatStringFromName("remoteIncomingPromptTCP", [session.client.host, session.client.port]);

    if (session.authentication === "PROMPT") {
      return new Promise(resolve => {
        let allow = Strings.browser.GetStringFromName("remoteIncomingPromptAllow");
        let deny = Strings.browser.GetStringFromName("remoteIncomingPromptDeny");
        let prompt = new Prompt({
          window: null,
          hint: "remotedebug",
          title,
          message: msg,
          buttons: [allow, deny],
          priority: 1,
        });
        prompt.show(data => {
          resolve(data.button === 0 ? DevToolsServer.AuthenticationResult.ALLOW : DevToolsServer.AuthenticationResult.DENY);
        });
      });
    }

    if (session.authentication !== "OOB_CERT" || !session.client.cert) {
      return DevToolsServer.AuthenticationResult.DENY;
    }

    return new Promise(resolve => {
      let scan = Strings.browser.GetStringFromName("remoteIncomingPromptScan");
      let scanAndRemember = Strings.browser.GetStringFromName("remoteIncomingPromptScanAndRemember");
      let deny = Strings.browser.GetStringFromName("remoteIncomingPromptDeny");
      let prompt = new Prompt({
        window: null,
        hint: "remotedebug",
        title,
        message: msg,
        buttons: [scan, scanAndRemember, deny],
        priority: 1,
      });
      prompt.show(data => {
        let result = data.button;
        if (result === 0) {
          resolve(DevToolsServer.AuthenticationResult.ALLOW);
        } else if (result === 1) {
          resolve(DevToolsServer.AuthenticationResult.ALLOW_PERSIST);
        } else {
          resolve(DevToolsServer.AuthenticationResult.DENY);
        }
      });
    });
  },

  receiveOOB() {
    if (this._receivingOOB) {
      return this._receivingOOB;
    }

    this._receivingOOB = WindowEventDispatcher.sendRequestForResult({
      type: "DevToolsAuth:Scan",
    }).then(
      data => JSON.parse(data),
      () => {
        let title = Strings.browser.GetStringFromName("remoteQRScanFailedPromptTitle");
        let msg = Strings.browser.GetStringFromName("remoteQRScanFailedPromptMessage");
        let ok = Strings.browser.GetStringFromName("remoteQRScanFailedPromptOK");
        let prompt = new Prompt({
          window: null,
          hint: "remotedebug",
          title,
          message: msg,
          buttons: [ok],
          priority: 1,
        });
        prompt.show();
      }
    );

    this._receivingOOB.then(() => (this._receivingOOB = null));
    return this._receivingOOB;
  },

  initServer() {
    DevToolsServer.init();
    DevToolsServer.registerAllActors();
    const { createRootActor } = require("resource://gre/modules/dbg-browser-actors.js");
    DevToolsServer.setRootActor(createRootActor);
    DevToolsServer.allowChromeProcess = true;
    DevToolsServer.chromeWindowType = this._windowType;
    DevToolsServer.keepAlive = true;
  },

  shutdownServerIfIdle() {
    if (this.isAnyEnabled) {
      return;
    }

    if (DevToolsServer.initialized) {
      try {
        DevToolsServer.closeAllSocketListeners();
      } catch (e) {
        dump("Unable to close debugger listeners: " + e + "\n");
      }
      Services.prefs.setBoolPref("devtools.debugger.remote-enabled", false);
      DevToolsServer.destroy();
    }
  },
};

RemoteDebugger.allowConnection = RemoteDebugger.allowConnection.bind(RemoteDebugger);
RemoteDebugger.receiveOOB = RemoteDebugger.receiveOOB.bind(RemoteDebugger);

var USBRemoteDebugger = {
  init() {
    Services.prefs.addObserver("devtools.", this);
    Services.prefs.setBoolPref("devtools.debugger.remote-enabled", RemoteDebugger.isAnyEnabled);
    if (this.isEnabled) {
      this.start();
    }
  },

  observe(subject, topic, data) {
    if (topic != "nsPref:changed") {
      return;
    }

    switch (data) {
      case "devtools.remote.usb.enabled":
        Services.prefs.setBoolPref("devtools.debugger.remote-enabled", RemoteDebugger.isAnyEnabled);
        if (this.isEnabled) {
          this.start();
        } else {
          this.stop();
        }
        break;
      case "devtools.debugger.remote-port":
      case "devtools.debugger.unix-domain-socket":
        if (this.isEnabled) {
          this.stop();
          this.start();
        }
        break;
    }
  },

  get isEnabled() {
    return Services.prefs.getBoolPref("devtools.remote.usb.enabled");
  },

  start() {
    if (this._listener) {
      return;
    }

    RemoteDebugger.initServer();
    const portOrPath = Services.prefs.getCharPref("devtools.debugger.unix-domain-socket") ||
      Services.prefs.getIntPref("devtools.debugger.remote-port");

    try {
      dump(`Starting USB debugger on ${portOrPath}\n`);
      const AuthenticatorType = DevToolsServer.Authenticators.get("PROMPT");
      const authenticator = new AuthenticatorType.Server();
      authenticator.allowConnection = RemoteDebugger.allowConnection;
      const socketOptions = { authenticator, portOrPath };
      this._listener = new SocketListener(DevToolsServer, socketOptions);
      this._listener.open();
    } catch (e) {
      dump("Unable to start USB debugger server: " + e);
    }
  },

  stop() {
    if (!this._listener) {
      RemoteDebugger.shutdownServerIfIdle();
      return;
    }

    try {
      this._listener.close();
      this._listener = null;
    } catch (e) {
      dump("Unable to stop USB debugger server: " + e);
    }

    RemoteDebugger.shutdownServerIfIdle();
  },
};

var WiFiRemoteDebugger = {
  init() {
    Services.prefs.addObserver("devtools.", this);
    Services.prefs.setBoolPref("devtools.debugger.remote-enabled", RemoteDebugger.isAnyEnabled);
    Services.prefs.setBoolPref("devtools.debugger.force-local", !this.isEnabled);
    if (this.isEnabled) {
      this.start();
    }
  },

  observe(subject, topic, data) {
    if (topic != "nsPref:changed") {
      return;
    }

    switch (data) {
      case "devtools.remote.wifi.enabled":
        Services.prefs.setBoolPref("devtools.debugger.remote-enabled", RemoteDebugger.isAnyEnabled);
        Services.prefs.setBoolPref("devtools.debugger.force-local", !this.isEnabled);
        if (this.isEnabled) {
          this.start();
        } else {
          this.stop();
        }
        break;
      case "devtools.debugger.remote-port":
        if (this.isEnabled) {
          this.stop();
          this.start();
        }
        break;
    }
  },

  get isEnabled() {
    return Services.prefs.getBoolPref("devtools.remote.wifi.enabled");
  },

  start() {
    if (this._listener) {
      return;
    }

    RemoteDebugger.initServer();
    try {
      dump("Starting WiFi debugger\n");
      const AuthenticatorType = DevToolsServer.Authenticators.get("PROMPT");
      const authenticator = new AuthenticatorType.Server();
      authenticator.allowConnection = RemoteDebugger.allowConnection;
      const socketOptions = {
        authenticator,
        discoverable: true,
        encryption: false,
        portOrPath: Services.prefs.getIntPref("devtools.debugger.remote-port"),
      };
      this._listener = new SocketListener(DevToolsServer, socketOptions);
      this._listener.open();
      dump("Started WiFi debugger on " + this._listener.port + "\n");
    } catch (e) {
      dump("Unable to start WiFi debugger server: " + e);
    }
  },

  stop() {
    if (!this._listener) {
      RemoteDebugger.shutdownServerIfIdle();
      return;
    }

    try {
      this._listener.close();
      this._listener = null;
    } catch (e) {
      dump("Unable to stop WiFi debugger server: " + e);
    }

    RemoteDebugger.shutdownServerIfIdle();
  },
};
