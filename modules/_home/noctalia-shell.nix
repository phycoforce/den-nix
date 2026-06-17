{ lib, pkgs, ... }:
let
  activeTemplates = [
    "gtk"
    "ghostty"
    "code"
    "niri"
    "qt"
    "starship"
  ];

  activeTemplatesJson = builtins.toJSON (
    map (id: {
      inherit id;
      enabled = true;
    }) activeTemplates
  );
in
{
  programs.noctalia-shell = {
    enable = true;

    colors = {
      mError = "#f38ba8";
      mHover = "#94e2d5";
      mOnError = "#11111b";
      mOnHover = "#11111b";
      mOnPrimary = "#11111b";
      mOnSecondary = "#11111b";
      mOnSurface = "#cdd6f4";
      mOnSurfaceVariant = "#a3b4eb";
      mOnTertiary = "#11111b";
      mOutline = "#4c4f69";
      mPrimary = "#cba6f7";
      mSecondary = "#fab387";
      mShadow = "#11111b";
      mSurface = "#1e1e2e";
      mSurfaceVariant = "#313244";
      mTertiary = "#94e2d5";
    };
  };

  home.activation.noctaliaActiveTemplates = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settingsFile="$HOME/.config/noctalia/settings.json"
    activeTemplates='${activeTemplatesJson}'
    fontDefault="Noto Sans"
    fontFixed="Noto Sans Mono"

    mkdir -p "$(dirname "$settingsFile")"
    tmp="$(${pkgs.coreutils}/bin/mktemp)"

    if [ -f "$settingsFile" ]; then
      if ! ${pkgs.jq}/bin/jq --argjson activeTemplates "$activeTemplates" \
        --arg fontDefault "$fontDefault" \
        --arg fontFixed "$fontFixed" \
        '.templates.activeTemplates = $activeTemplates
          | .templates.enableUserTheming = (.templates.enableUserTheming // false)
          | .ui.fontDefault = $fontDefault
          | .ui.fontFixed = $fontFixed
          | .location.autoLocate = true
          | .location.name = ""' \
        "$settingsFile" > "$tmp"; then
        rm -f "$tmp"
        exit 1
      fi
    else
      ${pkgs.jq}/bin/jq -n --argjson activeTemplates "$activeTemplates" \
        --arg fontDefault "$fontDefault" \
        --arg fontFixed "$fontFixed" \
        '{ templates: { activeTemplates: $activeTemplates, enableUserTheming: false },
           ui: { fontDefault: $fontDefault, fontFixed: $fontFixed },
           location: { autoLocate: true, name: "" } }' \
        > "$tmp"
    fi

    ${pkgs.coreutils}/bin/install -m 0644 "$tmp" "$settingsFile"
    rm -f "$tmp"
  '';
}
