"use strict";

const { Services } = ChromeUtils.import("resource://gre/modules/Services.jsm");
const { XPCOMUtils } = ChromeUtils.import("resource://gre/modules/XPCOMUtils.jsm");
const { AppConstants } = ChromeUtils.import("resource://gre/modules/AppConstants.jsm");

const isGonk = AppConstants.platform === "gonk";

if (isGonk) {
  XPCOMUtils.defineLazyGetter(this, "libcutils", function() {
    const { libcutils } = ChromeUtils.import("resource://gre/modules/systemlibs.js");
    return libcutils;
  });
}

XPCOMUtils.defineLazyServiceGetter(this, "gSettingsManager", "@mozilla.org/sidl-native/settings;1", "nsISettingsManager");
XPCOMUtils.defineLazyServiceGetter(this, "uuidgen", "@mozilla.org/uuid-generator;1", "nsIUUIDGenerator");

this.EXPORTED_SYMBOLS = ["SettingsPrefsSync"];

function settingCallback(message) {
  return {
    resolve: () => {},
    reject: () => {
      console.error(message);
    },
  };
}

const kSettingsToObserve = {
  "apz.overscroll.enabled": true,
  "browser.safebrowsing.enabled": true,
  "browser.safebrowsing.malware.enabled": true,
  "debug.fps.enabled": {
    prefName: "layers.acceleration.draw-fps",
    defaultValue: false,
  },
  "debug.paint-flashing.enabled": {
    prefName: "nglayout.debug.paint_flashing",
    defaultValue: false,
  },
  "device.storage.writable.name": "sdcard",
  "devtools.remote.usb.enabled": false,
  "devtools.remote.wifi.enabled": false,
  "gfx.layerscope.enabled": false,
  "layers.composer2d.enabled": false,
  "layers.draw-borders": false,
  "layers.draw-tile-borders": false,
  "layers.dump": false,
  "layers.effect.invert": false,
  "layers.enable-tiles": true,
  "mms.debugging.enabled": false,
  "network.debugging.enabled": false,
  "network.CaptivePortal.disabled": false,
  "privacy.donottrackheader.enabled": false,
  "privacy.trackingprotection.enabled": false,
  "ril.debugging.enabled": false,
  "ril.mms.requestReadReport.enabled": {
    prefName: "dom.mms.requestReadReport",
    defaultValue: true,
  },
  "ril.mms.requestStatusReport.enabled": {
    prefName: "dom.mms.requestStatusReport",
    defaultValue: false,
  },
  "ril.mms.retrieval_mode": {
    prefName: "dom.mms.retrieval_mode",
    defaultValue: "manual",
  },
  "ril.sms.requestStatusReport.enabled": {
    prefName: "dom.sms.requestStatusReport",
    defaultValue: false,
  },
  "ril.sms.strict7BitEncoding.enabled": {
    prefName: "dom.sms.strict7BitEncoding",
    defaultValue: false,
  },
  "ril.sms.maxReadAheadEntries": {
    prefName: "dom.sms.maxReadAheadEntries",
    defaultValue: 7,
  },
  "ui.prefers.color-theme": {
    prefName: "ui.systemUsesDarkTheme",
    defaultValue: 0,
    valueMap: { dark: 1 },
  },
  "ui.prefers.text-size": {
    prefName: "ui.prefersTextSizeId",
    defaultValue: 0,
    valueMap: { small: 1, large: 2 },
  },
  "voice-input.enabled": {
    resetToPref: true,
  },
  "voice-input.icon-url": {
    resetToPref: true,
  },
  "voice-input.supported-types": {
    resetToPref: true,
  },
};

this.SettingsPrefsSync = {
  start(aWindow) {
    this.window = aWindow;
    this.settingsObservers = [];
    Services.obs.addObserver(this, "xpcom-shutdown");
    return new Promise(resolve => {
      this.getSettingWithDefault("language.current", "en-US").then(setting => {
        this.updateLanguage(setting.value, true);
        resolve();
      });
    });
  },

  updateLanguage(value, forceSetPref) {
    Services.locale.requestedLocales = [value];
    let prefName = "intl.accept_languages";
    let intl = [];
    try {
      intl = Services.prefs
        .getComplexValue(prefName, Ci.nsIPrefLocalizedString)
        .data.split(",")
        .map(item => item.trim(" "));
    } catch (e) {}

    if (!intl.length) {
      Services.prefs.setCharPref(prefName, value);
    } else if (intl[0] != value) {
      Services.prefs.setCharPref(prefName, [value, intl.filter(item => item != value)].join(", "));
    } else if (forceSetPref) {
      Services.prefs.setCharPref(prefName, intl.join(", "));
    }
  },

  observe(subject, topic) {
    if (topic !== "xpcom-shutdown") {
      console.error(`SettingsPrefsSync: unexpected observer notification '${topic}'`);
      return;
    }

    Services.obs.removeObserver(this, "xpcom-shutdown");
    this.settingsObservers.forEach(item => {
      gSettingsManager.removeObserver(item.key, item.observer, settingCallback(`Failed to add observer for ${item.key}`));
    });
  },

  addSettingsObserver(key, observer, message) {
    gSettingsManager.addObserver(key, observer, settingCallback(message));
    this.settingsObservers.push({ key, observer });
  },

  getSettingWithDefault(name, defaultValue) {
    return new Promise(resolve => {
      gSettingsManager.get(name, {
        resolve: setting => {
          resolve({ name: setting.name, value: JSON.parse(setting.value) });
        },
        reject: () => {
          resolve({ name, value: defaultValue });
        },
      });
    });
  },

  delayedInit() {
    this.deviceInfoToSettings();
    this.setUpdateTrackingId();
    this.setupAccessibility();
    this.synchronizePrefs();
    this.setupLanguageSettingObserver();
    this.setupLowPrecisionSettings();
  },

  get cuRef() {
    let cuRefStr;
    dump("Cliff: SettingsPrefsSync.jsm, getting curef starts");
    try {
      cuRefStr =
        Services.prefs.getPrefType("device.commercial.ref") == Ci.nsIPrefBranch.PREF_STRING
          ? Services.prefs.getCharPref("device.commercial.ref")
          : undefined;
      if (!cuRefStr) {
        cuRefStr =
          Services.prefs.getPrefType("device.cuRef.default") == Ci.nsIPrefBranch.PREF_STRING
            ? Services.prefs.getCharPref("device.cuRef.default")
            : undefined;
      }
    } catch (e) {
      console.error(`get Commercial Unit Reference error: ${e}`);
    }
    dump(`Cliff: SettingsPrefsSync.jsm, curef = ${cuRefStr}`);
    return cuRefStr;
  },

  deviceInfoToSettings() {
    let os_version = AppConstants.MOZ_B2G_VERSION;
    let os_name = AppConstants.MOZ_B2G_OS_NAME;
    let hardware_info = null;
    let firmware_revision = null;
    let product_manufacturer = null;
    let product_model = null;
    let product_device = null;
    let build_number = null;
    let sar_info = null;
    let version_tag = null;
    let base_version = null;
    let product_fota = null;
    let cuRefStr = null;
    let build_fingerprint = null;

    if (isGonk) {
      hardware_info = libcutils.property_get("ro.boot.hardware.revision");
      firmware_revision = libcutils.property_get("ro.firmware_revision");
      product_manufacturer = libcutils.property_get("ro.product.manufacturer");
      product_model = libcutils.property_get("ro.product.model");
      product_device = libcutils.property_get("ro.product.device");
      build_number = libcutils.property_get("ro.build.version.incremental");
      sar_info = libcutils.property_get("ro.product.sar_value", "0");
      version_tag = libcutils.property_get("ro.product.version_tag");
      base_version = libcutils.property_get("ro.product.base_version");
      product_fota = libcutils.property_get("ro.product.fota");
      cuRefStr = this.cuRef || null;
      build_fingerprint = libcutils.property_get("ro.build.fingerprint");
    }

    this.getSettingWithDefault("deviceinfo.os", null).then(setting => {
      let previous_os = setting.value || "";
      let software = os_name + " " + os_version;
      let deviceInfo = {
        build_number,
        os: os_version,
        previous_os,
        software,
        platform_version: Services.appinfo.platformVersion,
        platform_build_id: Services.appinfo.platformBuildID,
        hardware: hardware_info,
        firmware_revision,
        product_manufacturer,
        product_model,
        product_device,
        sar_value: sar_info,
        software_tag: version_tag,
        base_version,
        product_fota,
        cu: cuRefStr,
        build_fingerprint,
      };

      let settingsArray = [];
      for (let name in deviceInfo) {
        settingsArray.push({
          name: `deviceinfo.${name}`,
          value: JSON.stringify(deviceInfo[name] || ""),
        });
      }
      gSettingsManager.set(settingsArray, settingCallback("Failure saving deviceinfo settings."));
    });
  },

  setUpdateTrackingId() {
    try {
      let trackingId =
        Services.prefs.getPrefType("app.update.custom") == Ci.nsIPrefBranch.PREF_STRING &&
        Services.prefs.getCharPref("app.update.custom");
      if (!trackingId) {
        trackingId = uuidgen.generateUUID().toString().replace(/[{}]/g, "");
        Services.prefs.setCharPref("app.update.custom", trackingId);
        gSettingsManager.set(
          [{ name: "app.update.custom", value: JSON.stringify(trackingId) }],
          settingCallback("Failure saving app.update.custom setting.")
        );
      }
    } catch (e) {
      dump("Error getting tracking ID " + e + "\n");
    }
  },

  updateAccessFu(value) {
    let accessibilityScope = {};
    if (!("AccessFu" in accessibilityScope)) {
      ChromeUtils.import("resource://gre/modules/accessibility/AccessFu.jsm", accessibilityScope);
    }
    if (value) {
      accessibilityScope.AccessFu.attach(this.window);
    } else {
      accessibilityScope.AccessFu.detach();
    }
  },

  setupAccessibility() {
    this.addSettingsObserver(
      "accessibility.screenreader",
      {
        observeSetting: info => {
          if (!info) {
            return;
          }
          let value = JSON.parse(info.value);
          this.updateAccessFu(value);
        },
      },
      "Failed to add a setting observer for accessibility.screenreader"
    );
    this.getSettingWithDefault("accessibility.screenreader", false).then(setting => {
      this.updateAccessFu(setting.value);
    });
  },

  synchronizePrefs() {
    gSettingsManager.getBatch(Object.keys(kSettingsToObserve), {
      resolve: results => {
        let syncSettings = {};
        results.forEach(result => {
          const { name, value } = result;
          syncSettings[name] = value;
        });

        for (let key in kSettingsToObserve) {
          let setting = kSettingsToObserve[key];
          let prefName = setting.prefName || key;
          let defaultValue = setting.defaultValue;
          if (defaultValue === undefined) {
            defaultValue = setting;
          }

          let prefs = Services.prefs;
          if (setting.resetToPref) {
            switch (prefs.getPrefType(prefName)) {
              case Ci.nsIPrefBranch.PREF_BOOL:
              default:
                defaultValue = prefs.getBoolPref(prefName);
                break;
              case Ci.nsIPrefBranch.PREF_INT:
                defaultValue = prefs.getIntPref(prefName);
                break;
              case Ci.nsIPrefBranch.PREF_STRING:
                defaultValue = prefs.getCharPref(prefName);
                break;
            }
            let settingItem = { name: key };
            settingItem.value = JSON.stringify(defaultValue);
            gSettingsManager.set([settingItem], settingCallback(`Failed to set setting ${key}`));
          }

          let setPref;
          switch (typeof defaultValue) {
            case "boolean":
              setPref = prefs.setBoolPref.bind(prefs);
              break;
            case "number":
              setPref = prefs.setIntPref.bind(prefs);
              break;
            case "string":
              setPref = prefs.setCharPref.bind(prefs);
              break;
          }

          let mapValue;
          if (setting.hasOwnProperty("valueMap")) {
            mapValue = v => (setting.valueMap.hasOwnProperty(v) ? setting.valueMap[v] : defaultValue);
          } else {
            mapValue = v => v;
          }

          if (!setting.resetToPref && syncSettings.hasOwnProperty(key)) {
            let value = JSON.parse(syncSettings[key]);
            setPref(prefName, mapValue(value));
          }

          this.addSettingsObserver(
            key,
            {
              observeSetting: info => {
                if (!info) {
                  return;
                }
                let value = JSON.parse(info.value);
                setPref(prefName, mapValue(value));
              },
            },
            `Failed to add observer for ${key}`
          );
        }
      },
      reject: error => {
        console.error(`SettingsPrefsSync: synchronizePrefs get settings failed:${JSON.stringify(error)}`);
      },
    });
  },

  setupLanguageSettingObserver() {
    this.addSettingsObserver(
      "language.current",
      {
        observeSetting: info => {
          if (!info) {
            return;
          }
          let value = JSON.parse(info.value);
          this.updateLanguage(value, false);
        },
      },
      "Failed to add observer for language.current"
    );
  },

  setupLowPrecisionSettings() {
    this.addSettingsObserver(
      "layers.low-precision",
      {
        observeSetting: info => {
          if (info !== null) {
            let value = JSON.parse(info.value);
            Services.prefs.setBoolPref("layers.low-precision-buffer", value);
            Services.prefs.setBoolPref("layers.progressive-paint", value);
          } else {
            try {
              let prefValue = Services.prefs.getBoolPref("layers.low-precision-buffer");
              let setting = [{ "layers.low-precision": prefValue }];
              gSettingsManager.set(setting, settingCallback("Failure saving low-precision-buffer settings."));
            } catch (e) {
              dump("Unable to read pref layers.low-precision-buffer: " + e);
            }
          }
        },
      },
      "Failed to add observer for low precision buffer"
    );

    this.addSettingsObserver(
      "layers.low-opacity",
      {
        observeSetting: info => {
          if (info !== null) {
            let value = JSON.parse(info.value);
            Services.prefs.setCharPref("layers.low-precision-opacity", value ? "0.5" : "1.0");
          } else {
            try {
              let prefValue = Services.prefs.getCharPref("layers.low-precision-opacity");
              let setting = [{ "layers.low-opacity": prefValue == "0.5" }];
              gSettingsManager.set(setting, settingCallback("Failure saving low-precision-opacity settings."));
            } catch (e) {
              dump("Unable to read pref layers.low-precision-opacity: " + e);
            }
          }
        },
      },
      "Failed to add observer for low precision opacity"
    );
  },
};
