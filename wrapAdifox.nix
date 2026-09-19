{types, ...}: {
  inputs = {
    nixpkgs.from = {root}: root.nixpkgs;
  };

  options = {
    package = {
      type = types.derivation;
    };

    applicationName = {
      type = types.string;
      defaultFunc = { options, inputs }:
        let inherit (inputs.nixpkgs) lib;
        in options.package.binaryName or (lib.getName options.package);
    };

    version = {
      type = types.string;
      defaultFunc = { options, inputs }:
        let inherit (inputs.nixpkgs) lib;
        in lib.getVersion options.package;
    };

    nameSuffix = {
      type = types.string;
      default = "";
    };

    icon = {
      type = types.string;
      defaultFunc = {options}: options.applicationName;
    };

    wmClass = {
      type = types.string;
      defaultFunc = {options}: options.applicationName;
    };

    nativeMessagingHosts = {
      type = types.listOf types.derivation;
      default = [];
    };

    pkcs11Modules = {
      type = types.listOf types.derivation;
      default = [];
    };

    nixExtensions = {
      type = types.listOf types.attrs;
      default = [];
    };

    useGlvnd = {
      type = types.bool;
      defaultFunc = {inputs}: !inputs.nixpkgs.pkgs.stdenv.hostPlatform.isDarwin;
    };

    hasMozSystemDirPatch = {
      type = types.bool;
      defaultFunc = { options, inputs }:
        let inherit (inputs.nixpkgs) lib;
        in lib.hasPrefix "firefox" options.applicationName && !lib.hasSuffix "-bin" options.applicationName;
    };

    extraPrefs = {
      type = types.string;
      default = "";
    };

    extraPrefsFiles = {
      type = types.listOf types.pathLike;
      default = [];
    };

    extraPolicies = {
      type = types.attrs;
      default = {};
    };

    extraPoliciesFiles = {
      type = types.listOf types.pathLike;
      default = [];
    };

    libName = {
      type = types.string;
      defaultFunc = {options}: options.package.libName or options.applicationName;
    };

    settings = {
      type = types.attrs;
      default = {};
    };
  };

  impl = { options, inputs }:
    let
      inherit (inputs.nixpkgs) lib pkgs;
      inherit (pkgs) stdenv;
      inherit (stdenv.hostPlatform) isDarwin;

      browser =
        if isDarwin
        then options.package.overrideAttrs (
          oldAttrs: lib.optionalAttrs (oldAttrs.dontFixup or false) {
            dontFixup = false;
          }
        )
        else options.package;

      ffmpegSupport = browser.ffmpegSupport or false;
      gssSupport = browser.gssSupport or false;
      alsaSupport = browser.alsaSupport or false;
      pipewireSupport = browser.pipewireSupport or false;
      sndioSupport = browser.sndioSupport or false;
      jackSupport = browser.jackSupport or false;
      smartcardSupport = options.settings.smartcardSupport or false;

      allNativeMessagingHosts = map lib.getBin (lib.unique options.nativeMessagingHosts);

      libs = lib.optionals stdenv.hostPlatform.isLinux (
        [
          pkgs.udev
          pkgs.libva
          pkgs.libgbm
          pkgs.libnotify
          pkgs.libxscrnsaver
          pkgs.cups
          pkgs.pciutils
          pkgs.vulkan-loader
        ]
        ++ lib.optional (options.settings.speechSynthesisSupport or true) pkgs.speechd-minimal
      )
      ++ lib.optional pipewireSupport pkgs.pipewire
      ++ lib.optional ffmpegSupport pkgs.ffmpeg_7
      ++ lib.optional gssSupport pkgs.libkrb5
      ++ lib.optional options.useGlvnd pkgs.libglvnd
      ++ lib.optionals (options.settings.enableQuakeLive or false) [
        stdenv.cc
        pkgs.libx11
        pkgs.libxxf86dga
        pkgs.libxxf86vm
        pkgs.libxext
        pkgs.libxt
        pkgs.alsa-lib
        pkgs.zlib
      ]
      ++ lib.optional (pkgs.config.pulseaudio or (!isDarwin)) pkgs.libpulseaudio
      ++ lib.optional alsaSupport pkgs.alsa-lib
      ++ lib.optional sndioSupport pkgs.sndio
      ++ lib.optional jackSupport pkgs.libjack2
      ++ lib.optional smartcardSupport pkgs.opensc
      ++ options.pkcs11Modules
      ++ lib.optionals (!isDarwin) gtk_modules;

      gtk_modules = lib.optionals (!isDarwin) [pkgs.libcanberra-gtk3];

      launcherName = "${options.applicationName}${lib.optionalString (!isDarwin) options.nameSuffix}";

      usesNixExtensions = options.nixExtensions != [];

      nameArray = map (a: a.name) (lib.optionals usesNixExtensions options.nixExtensions);

      extensions =
        if nameArray != (lib.unique nameArray)
        then throw "Firefox addon name needs to be unique"
        else if browser.requireSigning || !browser.allowAddonSideload
        then throw "Nix addons are only supported with signature enforcement disabled and addon sideloading enabled (eg. LibreWolf)"
        else map (
          a: if !(builtins.hasAttr "extid" a)
            then throw "nixExtensions has an invalid entry. Missing extid attribute. Please use fetchFirefoxAddon"
            else a
        ) (lib.optionals usesNixExtensions options.nixExtensions);

      enterprisePolicies = {
        policies =
          {
            DisableAppUpdate = true;
          }
          // lib.optionalAttrs usesNixExtensions {
            ExtensionSettings = {
              "*" = {
                blocked_install_message = "You can't have manual extension mixed with nix extensions";
                installation_mode = "blocked";
              };
            } // builtins.foldl' (
              e: ret: ret // {
                "${e.extid}" = {
                  installation_mode = "allowed";
                };
              }
            ) {} extensions;

            Extensions = {
              Install = builtins.foldl' (e: ret: ret ++ ["${e.outPath}/${e.extid}.xpi"]) [] extensions;
            };
          }
          // lib.optionalAttrs smartcardSupport {
            SecurityDevices = {
              "OpenSC PKCS#11 Module" = "opensc-pkcs11.so";
            };
          }
          // options.extraPolicies;
      };

      policiesJson = pkgs.writeText "policies.json" (builtins.toJSON enterprisePolicies);

      mozillaCfg = ''
        // First line must be a comment
        ${lib.optionalString usesNixExtensions ''lockPref("xpinstall.signatures.required", false);''}
      '';

      desktopItem = pkgs.makeDesktopItem (
        {
          name = launcherName;
          exec = "${launcherName} --name ${options.wmClass} %U";
          icon = options.icon;
          desktopName = browser.applicationName;
          startupNotify = true;
          startupWMClass = options.wmClass;
          terminal = false;
        }
        // (
          if options.libName == "thunderbird"
          then {
            genericName = "Email Client";
            comment = "Read and write e-mails or RSS feeds, or manage tasks on calendars.";
            categories = ["Network" "Chat" "Email" "Feed" "GTK" "News"];
            keywords = ["mail" "email" "e-mail" "messages" "rss" "calendar" "address book" "addressbook" "chat"];
            mimeTypes = ["message/rfc822" "x-scheme-handler/mailto" "text/calendar" "text/x-vcard"];
            actions = {
              profile-manager-window = {
                name = "Profile Manager";
                exec = "${launcherName} --ProfileManager";
              };
            };
          }
          else {
            genericName = "Web Browser";
            categories = ["Network" "WebBrowser"];
            mimeTypes = ["text/html" "text/xml" "application/xhtml+xml" "application/vnd.mozilla.xul+xml" "x-scheme-handler/http" "x-scheme-handler/https"];
            actions = {
              new-window = {
                name = "New Window";
                exec = "${launcherName} --new-window %U";
              };
              new-private-window = {
                name = "New Private Window";
                exec = "${launcherName} --private-window %U";
              };
              profile-manager-window = {
                name = "Profile Manager";
                exec = "${launcherName} --ProfileManager";
              };
            };
          }
        )
      );
    in
      stdenv.mkDerivation (finalAttrs: {
        __structuredAttrs = true;
        pname = options.applicationName;
        version = options.version;

        inherit desktopItem;

        nativeBuildInputs = [
          pkgs.makeBinaryWrapper
          pkgs.lndir
          pkgs.jq
        ];
        buildInputs = lib.optionals (!isDarwin) [browser.gtk3];

        makeWrapperArgs = [
          "--prefix" "LD_LIBRARY_PATH" ":" "${finalAttrs.libs}"
          "--suffix" "PATH" ":" "${placeholder "out"}/bin"
          "--set" "MOZ_APP_LAUNCHER" launcherName
          "--set" "MOZ_LEGACY_PROFILES" "1"
          "--set" "MOZ_ALLOW_DOWNGRADE" "1"
        ]
        ++ lib.optionals (!isDarwin) [
          "--suffix" "GTK_PATH" ":" "${lib.concatStringsSep ":" finalAttrs.gtk_modules}"
          "--suffix" "XDG_DATA_DIRS" ":" "${pkgs.adwaita-icon-theme}/share"
          "--set-default" "MOZ_ENABLE_WAYLAND" "1"
        ]
        ++ lib.optionals (!pkgs.xdg-utils.meta.broken && !isDarwin) [
          "--suffix" "PATH" ":" "${lib.makeBinPath [pkgs.xdg-utils]}"
        ]
        ++ lib.optionals options.hasMozSystemDirPatch [
          "--set" "MOZ_SYSTEM_DIR" "${placeholder "out"}/lib/mozilla"
        ]
        ++ lib.optionals (!options.hasMozSystemDirPatch && allNativeMessagingHosts != []) [
          "--run" "mkdir -p \${MOZ_HOME:-~/.mozilla}/native-messaging-hosts"
        ]
        ++ lib.optionals (!options.hasMozSystemDirPatch) (
          builtins.concatMap (ext: [
            "--run" "ln -sfLt \${MOZ_HOME:-~/.mozilla}/native-messaging-hosts ${ext}/lib/mozilla/native-messaging-hosts/*"
          ]) allNativeMessagingHosts
        );

        buildCommand = let
          appPath = "Applications/${browser.applicationName}.app";
          executablePrefix = if isDarwin then "${appPath}/Contents/MacOS" else "bin";
          executablePath = "${executablePrefix}/${options.applicationName}";
          finalBinaryPath = "${executablePath}${lib.optionalString (!isDarwin) "${options.nameSuffix}"}";
          sourceBinary = "${browser}/${executablePath}";
          libDir = if isDarwin then "${appPath}/Contents/Resources" else "lib/${options.libName}";
          prefsDir = if isDarwin then "${libDir}/browser/defaults/preferences" else "${libDir}/defaults/pref";
        in
        # bash
        ''
          if [ ! -x "${sourceBinary}" ]; then
            echo "cannot find executable file \`${sourceBinary}'"
            exit 1
          fi

          cd "${browser}"
          find . -type d -exec mkdir -p "$out"/{} \;
          find . -type f \( -not -name "${options.applicationName}" \) -exec ln -sT "${browser}"/{} "$out"/{} \;
          find . -type f \( -name "${options.applicationName}" -o -name "${options.applicationName}-bin" \) -print0 | while read -d $'\0' f; do
            cp -P --no-preserve=mode,ownership --remove-destination "${browser}/$f" "$out/$f"
            chmod a+rwx "$out/$f"
          done
          find . -type l -print0 | while read -d $'\0' l; do
            target="$(readlink "$l")"
            target=''${target/#"${browser}"/"$out"}
            ln -sfT "$target" "$out/$l"
          done
          cd "$out"

        '' + lib.optionalString isDarwin ''
          cd "${appPath}"
          for file in $(find . -name "omni.ja" -o -name "*.dylib"); do
            rm "$file"
            cp "${browser}/${appPath}/$file" "$file"
          done
          for dir in $(find . -type d -name '*.app'); do
            rm -r "$dir"
            cp -r "${browser}/${appPath}/$dir" "$dir"
          done
          cd ..
        '' + ''

          executablePrefix="$out/${executablePrefix}"
          executablePath="$out/${executablePath}"
          oldWrapperArgs=()

          if [[ -L $executablePath ]]; then
            oldExe="$(readlink -v --canonicalize-existing "$executablePath")"
            rm "$executablePath"
          elif wrapperCmd=$(${pkgs.buildPackages.makeBinaryWrapper.extractCmd} "$executablePath"); [[ $wrapperCmd ]]; then
            parseMakeCWrapperCall() { shift; oldExe=$1; shift; oldWrapperArgs=("$@"); }
            eval "parseMakeCWrapperCall ''${wrapperCmd//"${browser}"/"$out"}"
            rm "$executablePath"
          else
            if read -rn2 shebang < "$executablePath" && [[ $shebang == '#!' ]]; then
              sed -i "s@${browser}@$out@g" "$executablePath"
            fi
            oldExe="$executablePrefix/.${options.applicationName}"-old
            mv "$executablePath" "$oldExe"
          fi
        '' + lib.optionalString (!isDarwin) ''
          appendToVar makeWrapperArgs --prefix XDG_DATA_DIRS : "$GSETTINGS_SCHEMAS_PATH"
        '' + ''
          concatTo makeWrapperArgs oldWrapperArgs
          makeWrapper "$oldExe" "$out/${finalBinaryPath}" "''${makeWrapperArgs[@]}"
        '' + lib.optionalString (!isDarwin) ''
          if [ -e "${browser}/share/icons" ]; then
            mkdir -p "$out/share"
            ln -s "${browser}/share/icons" "$out/share/icons"
          else
            for res in 16 32 48 64 128; do
              mkdir -p "$out/share/icons/hicolor/''${res}x''${res}/apps"
              icon=$( find "${browser}/lib/" -name "default''${res}.png" )
              if [ -e "$icon" ]; then ln -s "$icon" "$out/share/icons/hicolor/''${res}x''${res}/apps/${options.icon}.png"; fi
            done
          fi
          install -m 644 -D -t $out/share/applications $desktopItem/share/applications/*
        '' + lib.optionalString options.hasMozSystemDirPatch ''
          mkdir -p $out/lib/mozilla/native-messaging-hosts
          for ext in ${toString allNativeMessagingHosts}; do
            ln -sLt $out/lib/mozilla/native-messaging-hosts $ext/lib/mozilla/native-messaging-hosts/*
          done
        '' + ''

          mkdir -p $out/lib/mozilla/pkcs11-modules
          for ext in ${toString options.pkcs11Modules}; do
            ln -sLt $out/lib/mozilla/pkcs11-modules $ext/lib/mozilla/pkcs11-modules/*
          done

          libDir="$out/${libDir}"
          mkdir -p "$libDir/distribution"

          POL_PATH="$libDir/distribution/policies.json"
          rm -f "$POL_PATH"
          cat ${policiesJson} >> "$POL_PATH"

          ${lib.concatMapStringsSep "\n" (f: ''
            jq -s '.[0] * .[1]' ${f} "$POL_PATH" > .tmp.json
            mv .tmp.json "$POL_PATH"
          '') options.extraPoliciesFiles}

          prefsDir="$out/${prefsDir}"
          mkdir -p "$prefsDir"

          echo 'pref("general.config.filename", "mozilla.cfg");' > "$prefsDir/autoconfig.js"
          echo 'pref("general.config.obscure_value", 0);' >> "$prefsDir/autoconfig.js"

          cat > "$libDir/mozilla.cfg" << EOF
          ${mozillaCfg}
          EOF

          ${lib.concatMapStringsSep "\n" (f: "cat ${f} >> $libDir/mozilla.cfg") options.extraPrefsFiles}

          cat >> "$libDir/mozilla.cfg" << EOF
          ${options.extraPrefs}
          EOF

          mkdir -p "$libDir/distribution/extensions"
        '';

        preferLocalBuild = true;

        libs = lib.makeLibraryPath libs + ":" + lib.makeSearchPathOutput "lib" "lib64" libs;
        gtk_modules = map (x: x + x.gtkModule) gtk_modules;

        passthru = { unwrapped = browser; };

        disallowedRequisites = [stdenv.cc];
        meta = browser.meta // {
          inherit (browser.meta) description;
          mainProgram = launcherName;
          hydraPlatforms = [];
          priority = (browser.meta.priority or lib.meta.defaultPriority) - 1;
        };
      });
}
