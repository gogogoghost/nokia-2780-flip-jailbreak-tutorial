'use strict';
define(function(require) { // eslint-disable-line
  const SettingsPanel = require('modules/settings_panel');
  const Developer = require('panels/developer/developer');

  return function createDeveloperPanel() {
    let developElements = null;
    let currentPanel = null;
    const developer = Developer();

    function developerHandleKeyDown(e) {
      switch (e.key) {
        case 'Accept':
        case 'Enter': {
          const focusedElement = currentPanel.querySelector('.focus');
          if (focusedElement.id === 'remote-debugging') {
            const select = focusedElement.querySelector('select');
            select.focus();
          }
          break;
        }
        default:
          break;
      }
    }

    return SettingsPanel({
      onInit(panel) {
        currentPanel = panel;
        const elements = {
          ftuLauncher: panel.querySelector('.ftuLauncher'),
          softwareHomeButton: panel.querySelector('.software-home-button'),
          homegesture: panel.querySelector('.homegesture')
        };
        developer.init(elements);
        developElements = {
          header: panel.querySelector('#develope-tools-header'),
          toolWifi: panel.querySelector('#dev-tool-wifi'),
          devToolWifiSpan: panel.querySelector('#dev-tool-wifi span'),
          wifiDebuggingSpan: panel.querySelector('#wifi-debugging span'),
          toolDmserver: panel.querySelector('#dev-tool-dmserver'),
          toolHud: panel.querySelector('#dev-tool-hud'),
          toolPsu: panel.querySelector('#dev-tool-psu'),
          graphicsHeader: panel.querySelector('#graphics-settings-header'),
          graphicsSettings: panel.querySelector('#graphics-settings'),
          winMngHeader: panel.querySelector('#win-mng-settings-header'),
          winMngSettings: panel.querySelector('#win-mng-settings'),
          debugHeader: panel.querySelector('#debug-settings-header'),
          debugSettings: panel.querySelector('#debug-settings')
        };
        developElements.devToolWifiSpan.setAttribute(
          'data-l10n-id',
          Customization.getWifiCertifiedStrId('dev-tools-wifi', 'dev-tools-wlan')
        );

        developElements.wifiDebuggingSpan.setAttribute(
          'data-l10n-id',
          Customization.getWifiCertifiedStrId('wifi-debugging', 'wlan-debugging')
        );
      },

      onBeforeShow() {
        SettingsSoftkey.init(SoftParams.defaultSelect);
        SettingsSoftkey.show();
        window.addEventListener('keydown', developerHandleKeyDown);
        DeviceFeature.ready(() => {
          if (DeviceFeature.getValue('buildType') === 'user') {
            developElements.header.classList.add('hidden');
            developElements.toolWifi.classList.add('hidden');
            developElements.toolDmserver.classList.add('hidden');
            developElements.toolHud.classList.add('hidden');
            developElements.toolPsu.classList.add('hidden');
            developElements.graphicsHeader.classList.add('hidden');
            developElements.graphicsSettings.classList.add('hidden');
            developElements.winMngHeader.classList.add('hidden');
            developElements.winMngSettings.classList.add('hidden');
            developElements.debugHeader.classList.add('hidden');
            developElements.debugSettings.classList.add('hidden');
          }
        });
      },

      onBeforeHide() {
        SettingsSoftkey.hide();
        window.removeEventListener('keydown', developerHandleKeyDown);
      }
    });
  };
});
