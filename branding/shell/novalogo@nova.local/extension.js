// NOVA Shell — replaces GNOME's "Activities" with a NOVA logo button that
// opens a full-screen app launcher (Launchpad/Start style), and ships its own
// panel styling (see stylesheet.css). Additive — no fragile full shell theme.
import Gio from 'gi://Gio';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const LOGO = '/usr/share/nova/logo.png';

const NovaButton = GObject.registerClass(
class NovaButton extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'NOVA', true);   // dontCreateMenu = true
        this.add_style_class_name('nova-logo-button');
        const icon = new St.Icon({
            gicon: Gio.icon_new_for_string(LOGO),
            icon_size: 20,
            style_class: 'nova-logo-icon',
        });
        this.add_child(icon);
        this.connect('button-press-event', () => {
            // Click the logo → full-screen launcher (apps + type-to-search).
            if (Main.overview.visible) {
                Main.overview.hide();
            } else {
                try { Main.overview.showApps(); }
                catch (e) { Main.overview.show(); }
            }
            return Clutter.EVENT_STOP;
        });
    }
});

export default class NovaShell extends Extension {
    enable() {
        // Hide GNOME's "Activities" — the NOVA logo replaces it.
        this._activities = Main.panel.statusArea.activities;
        if (this._activities)
            this._activities.container.hide();

        this._btn = new NovaButton();
        Main.panel.addToStatusArea('nova-logo', this._btn, 0, 'left');
    }

    disable() {
        if (this._activities)
            this._activities.container.show();
        this._activities = null;
        this._btn?.destroy();
        this._btn = null;
    }
}
