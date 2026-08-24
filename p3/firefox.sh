export DISPLAY=:1
xhost +si:localuser:$USER
env DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus firefox "$@" &