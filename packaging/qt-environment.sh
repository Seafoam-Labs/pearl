# Read Pearl's fixed marker as data. Never execute user configuration as shell code.
# Loaded before application startup, including UWSM's activation environment.
if [ "${AQUEOUS_NESTED:-}" != 1 ]; then
    pearl_qt_marker=${XDG_CONFIG_HOME:-${HOME}/.config}/pearl/qt/session.conf
    pearl_qt_platform=
    if [ -f "$pearl_qt_marker" ] && [ ! -L "$pearl_qt_marker" ]; then
        case $(cat -- "$pearl_qt_marker") in
            'QT_QPA_PLATFORMTHEME=qtengine') pearl_qt_platform=qtengine ;;
            # Retain working pre-migration sessions until QtEngine can be applied.
            'QT_QPA_PLATFORMTHEME=qt5ct') pearl_qt_platform=qt5ct ;;
        esac
    fi
    if [ -n "$pearl_qt_platform" ]; then
        case ${QT_QPA_PLATFORMTHEME:-} in
            ''|qt5ct|qt6ct|qtengine) export QT_QPA_PLATFORMTHEME="$pearl_qt_platform" ;;
            *) : ;; # Retain an explicit conflicting platform integration.
        esac
    fi
    unset pearl_qt_marker pearl_qt_platform
fi
