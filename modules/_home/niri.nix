{
  config,
  lib,
  pkgs,
  ...
}:
let
  noctaliaIpc = "noctalia-shell ipc call";
  starshipConfigPath = "${config.xdg.configHome}/noctalia/starship.toml";
  niriNoctaliaConfig = pkgs.writeText "niri-noctalia.kdl" ''
    layout {
        focus-ring {
            active-color "#cba6f7"
            inactive-color "#1e1e2e"
            urgent-color "#f38ba8"
        }

        border {
            active-color "#cba6f7"
            inactive-color "#1e1e2e"
            urgent-color "#f38ba8"
        }

        shadow {
            color "#11111b70"
        }

        tab-indicator {
            active-color "#cba6f7"
            inactive-color "#6b02e9"
            urgent-color "#f38ba8"
        }

        insert-hint {
            color "#cba6f780"
        }
    }

    recent-windows {
        highlight {
            active-color "#cba6f7"
            urgent-color "#f38ba8"
        }
    }
  '';
in
{
  xdg.configFile = {
    "niri/config.kdl".text = ''
      include "./cfg/autostart.kdl"
      include "./cfg/keybinds.kdl"
      include "./cfg/input.kdl"
      include "./cfg/display.kdl"
      include "./cfg/layout.kdl"
      include "./cfg/rules.kdl"
      include "./cfg/misc.kdl"

      include "./noctalia.kdl"
    '';

    "niri/cfg/autostart.kdl".text = ''
      spawn-at-startup "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
      spawn-at-startup "xwayland-satellite"
      spawn-at-startup "noctalia-shell"
    '';

    "niri/cfg/display.kdl".text = ''
      /- output "DP-1" {
          mode "2560x1440@359.979"
          scale 1
      }
    '';

    "niri/cfg/input.kdl".text = ''
      input {
          keyboard {
              xkb {
                  layout "us"
              }
              numlock
          }

          touchpad {
              tap
              natural-scroll
          }

          workspace-auto-back-and-forth
      }
    '';

    "niri/cfg/keybinds.kdl".text = ''
      binds {
          Mod+Shift+Escape { show-hotkey-overlay; }

          Mod+Return { spawn "ghostty"; }
          Mod+Ctrl+Return { spawn-sh "${noctaliaIpc} launcher toggle"; }
          Mod+B { spawn "firefox"; }
          Mod+Alt+L { spawn-sh "${noctaliaIpc} lockScreen lock"; }
          Mod+Shift+Q { spawn-sh "${noctaliaIpc} sessionMenu toggle"; }
          Mod+E { spawn "nautilus"; }

          XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "${noctaliaIpc} volume increase"; }
          XF86AudioLowerVolume allow-when-locked=true { spawn-sh "${noctaliaIpc} volume decrease"; }
          XF86AudioMute allow-when-locked=true { spawn-sh "${noctaliaIpc} volume muteOutput"; }
          XF86AudioMicMute allow-when-locked=true { spawn-sh "${noctaliaIpc} volume muteInput"; }

          Mod+Q { close-window; }

          Mod+Left { focus-column-left; }
          Mod+H { focus-column-left; }
          Mod+Right { focus-column-right; }
          Mod+L { focus-column-right; }
          Mod+Up { focus-window-up; }
          Mod+K { focus-window-up; }
          Mod+Down { focus-window-down; }
          Mod+J { focus-window-down; }

          Mod+Ctrl+Left { move-column-left; }
          Mod+Ctrl+H { move-column-left; }
          Mod+Ctrl+Right { move-column-right; }
          Mod+Ctrl+L { move-column-right; }
          Mod+Ctrl+Up { move-window-up; }
          Mod+Ctrl+K { move-window-up; }
          Mod+Ctrl+Down { move-window-down; }
          Mod+Ctrl+J { move-window-down; }

          Mod+Home { focus-column-first; }
          Mod+End { focus-column-last; }
          Mod+Ctrl+Home { move-column-to-first; }
          Mod+Ctrl+End { move-column-to-last; }

          Mod+Shift+Left { focus-monitor-left; }
          Mod+Shift+Right { focus-monitor-right; }
          Mod+Shift+Up { focus-monitor-up; }
          Mod+Shift+Down { focus-monitor-down; }

          Mod+Shift+Ctrl+Left { move-column-to-monitor-left; }
          Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }
          Mod+Shift+Ctrl+Up { move-column-to-monitor-up; }
          Mod+Shift+Ctrl+Down { move-column-to-monitor-down; }

          Mod+WheelScrollDown cooldown-ms=150 { focus-workspace-down; }
          Mod+WheelScrollUp cooldown-ms=150 { focus-workspace-up; }
          Mod+Ctrl+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
          Mod+Ctrl+WheelScrollUp cooldown-ms=150 { move-column-to-workspace-up; }

          Mod+WheelScrollRight { focus-column-right; }
          Mod+WheelScrollLeft { focus-column-left; }
          Mod+Ctrl+WheelScrollRight { move-column-right; }
          Mod+Ctrl+WheelScrollLeft { move-column-left; }

          Mod+Shift+WheelScrollDown { focus-column-right; }
          Mod+Shift+WheelScrollUp { focus-column-left; }
          Mod+Ctrl+Shift+WheelScrollDown { move-column-right; }
          Mod+Ctrl+Shift+WheelScrollUp { move-column-left; }

          Mod+1 { focus-workspace 1; }
          Mod+2 { focus-workspace 2; }
          Mod+3 { focus-workspace 3; }
          Mod+4 { focus-workspace 4; }
          Mod+5 { focus-workspace 5; }
          Mod+6 { focus-workspace 6; }
          Mod+7 { focus-workspace 7; }
          Mod+8 { focus-workspace 8; }
          Mod+9 { focus-workspace 9; }

          Mod+Ctrl+1 { move-column-to-workspace 1; }
          Mod+Ctrl+2 { move-column-to-workspace 2; }
          Mod+Ctrl+3 { move-column-to-workspace 3; }
          Mod+Ctrl+4 { move-column-to-workspace 4; }
          Mod+Ctrl+5 { move-column-to-workspace 5; }
          Mod+Ctrl+6 { move-column-to-workspace 6; }
          Mod+Ctrl+7 { move-column-to-workspace 7; }
          Mod+Ctrl+8 { move-column-to-workspace 8; }
          Mod+Ctrl+9 { move-column-to-workspace 9; }

          Mod+Tab { focus-workspace-previous; }

          Mod+Ctrl+F { expand-column-to-available-width; }
          Mod+C { center-column; }
          Mod+Ctrl+C { center-visible-columns; }
          Mod+Minus { set-column-width "-10%"; }
          Mod+Equal { set-column-width "+10%"; }
          Mod+Shift+Minus { set-window-height "-10%"; }
          Mod+Shift+Equal { set-window-height "+10%"; }

          Mod+T { toggle-window-floating; }
          Mod+F { fullscreen-window; }
          Mod+W { toggle-column-tabbed-display; }

          Ctrl+Shift+1 { screenshot; }
          Ctrl+Shift+2 { screenshot-screen; }
          Ctrl+Shift+3 { screenshot-window; }

          Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }

          Ctrl+Alt+Delete { quit; }
          Mod+Shift+P { power-off-monitors; }
          Mod+O repeat=false { toggle-overview; }
      }
    '';

    "niri/cfg/layout.kdl".text = ''
      layout {
          gaps 16
          center-focused-column "never"
          background-color "transparent"

          preset-column-widths {
              proportion 0.33333
              proportion 0.5
              proportion 0.66667
          }

          struts {}
      }
    '';

    "niri/cfg/misc.kdl".text = ''
      prefer-no-csd
      screenshot-path null

      environment {
          ELECTRON_OZONE_PLATFORM_HINT "auto"
          NIXOS_OZONE_WL "1"
          QT_QPA_PLATFORM "wayland"
          QT_QPA_PLATFORMTHEME "qt6ct"
          QT_WAYLAND_DISABLE_WINDOWDECORATION "1"
          STARSHIP_CONFIG "${starshipConfigPath}"
          XDG_CURRENT_DESKTOP "niri"
          XDG_SESSION_TYPE "wayland"
      }

      debug {
          honor-xdg-activation-with-invalid-serial
      }

      hotkey-overlay {
          skip-at-startup
      }

      overview {
          workspace-shadow {
              off
          }
      }
    '';

    "niri/cfg/rules.kdl".text = ''
      window-rule {
          geometry-corner-radius 20
          clip-to-geometry true
      }

      layer-rule {
          match namespace="^noctalia-wallpaper*"
          place-within-backdrop true
      }
    '';

  };

  home.activation.niriNoctaliaConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="$HOME/.config/niri/noctalia.kdl"
    seed="${niriNoctaliaConfig}"

    mkdir -p "$(dirname "$target")"
    if [ ! -e "$target" ] || [ -L "$target" ]; then
      rm -f "$target"
      ${pkgs.coreutils}/bin/install -m 0644 "$seed" "$target"
    fi
  '';
}
