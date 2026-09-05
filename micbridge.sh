#!/data/data/com.termux/files/usr/bin/bash

echo "[+] Installing required dependencies..."
pkg update -y && pkg install python libusb jq termux-api -y
pip install pyusb

# 1. Create Python USB Bridge Engine
cat << 'PYEOF' > $PREFIX/bin/usb_bridge.py
import sys, os, socket, select, time, usb.core, usb.util

if len(sys.argv) < 3:
    sys.exit(1)

fd = int(sys.argv[1])
log_file = sys.argv[2]
os.environ['TERMUX_USB_FD'] = str(fd)

try:
    dev = usb.core.find()
    if dev is None:
        with open(log_file, "w") as f:
            f.write("[-] PyUSB failed to access USB device.\n")
        sys.exit(1)

    vid = dev.idVendor
    pid = dev.idProduct

    try:
        dev.set_configuration()
    except Exception:
        pass

    try:
        cfg = dev.get_active_configuration()
    except Exception:
        cfg = dev[0]

    ep_out = None
    ep_in = None

    for intf in cfg:
        try:
            if dev.is_kernel_driver_active(intf.bInterfaceNumber):
                dev.detach_kernel_driver(intf.bInterfaceNumber)
        except Exception:
            pass
        try:
            usb.util.claim_interface(dev, intf.bInterfaceNumber)
        except Exception:
            pass

        for ep in intf:
            ep_type = usb.util.endpoint_type(ep.bmAttributes)
            ep_dir = usb.util.endpoint_direction(ep.bEndpointAddress)
            if ep_type == usb.util.ENDPOINT_TYPE_BULK:
                if ep_dir == usb.util.ENDPOINT_OUT and ep_out is None:
                    ep_out = ep
                elif ep_dir == usb.util.ENDPOINT_IN and ep_in is None:
                    ep_in = ep

    if ep_out is None or ep_in is None:
        with open(log_file, "w") as f:
            f.write(f"[-] Could not find Bulk endpoints! VID:{hex(vid)} PID:{hex(pid)}\n")
        sys.exit(1)

    if vid in [0x2341, 0x2a03, 0x03eb]:
        try:
            dev.ctrl_transfer(0x21, 0x20, 0, 0, b'\x00\xc2\x01\x00\x00\x00\x08')
        except Exception:
            pass
    elif vid == 0x1a86:
        try:
            dev.ctrl_transfer(0x40, 0xa1, 0, 0, None)
            dev.ctrl_transfer(0x40, 0x9a, 0x1312, 0xd982, None)
            dev.ctrl_transfer(0x40, 0x9a, 0x0f2c, 0x0007, None)
        except Exception:
            pass

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', 8888))
    server.listen(1)

    with open(log_file, "w") as f:
        f.write("=======================================================\n")
        f.write(f"   NATIVE TCP USB BRIDGE IS LIVE! (VID:{hex(vid)})\n")
        f.write("   Listening on: 127.0.0.1:8888\n")
        f.write("=======================================================\n")

    while True:
        conn, addr = server.accept()
        conn.setblocking(False)

        if vid in [0x2341, 0x2a03, 0x03eb]:
            try:
                dev.ctrl_transfer(0x21, 0x22, 0x00, 0, None)
                time.sleep(0.05)
                dev.ctrl_transfer(0x21, 0x22, 0x03, 0, None)
            except Exception:
                pass

        try:
            while True:
                r, _, _ = select.select([conn], [], [], 0.001)
                if conn in r:
                    data = conn.recv(1024)
                    if not data:
                        break
                    ep_out.write(data, timeout=500)

                try:
                    usb_data = ep_in.read(1024, timeout=5)
                    if usb_data:
                        conn.sendall(bytes(usb_data))
                except usb.core.USBError:
                    pass
        except Exception:
            pass
        finally:
            conn.close()

except Exception as e:
    with open(log_file, "w") as f:
        f.write(f"[-] Bridge error: {e}\n")
PYEOF

# 2. Create mic-usb CLI Launcher
cat << 'CLIEOF' > $PREFIX/bin/mic-usb
#!/data/data/com.termux/files/usr/bin/bash

LOG_FILE="$HOME/bridge.log"

if [ -n "$1" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
  python3 $PREFIX/bin/usb_bridge.py "$1" "$LOG_FILE" > /dev/null 2>&1 &
  exit 0
fi

if [ "$1" = "--start" ]; then
  pkill -9 -f python 2>/dev/null
  pkill -9 -f usb_bridge.py 2>/dev/null
  rm -f "$LOG_FILE"
  sleep 0.5

  USB_DEV=$(termux-usb -l | jq -r '.[0]')
  if [ "$USB_DEV" = "null" ] || [ -z "$USB_DEV" ]; then
    echo "[-] No USB board detected! Re-plug OTG cable."
    exit 1
  fi

  echo "[+] Requesting USB permission..."
  termux-usb -r -e "$PREFIX/bin/mic-usb" "$USB_DEV"

  echo -n "[+] Starting bridge"
  for i in {1..20}; do
    if [ -f "$LOG_FILE" ]; then
      echo -e "\n"
      cat "$LOG_FILE"
      exit 0
    fi
    echo -n "."
    sleep 0.5
  done

  echo -e "\n[-] Bridge failed to start. Re-plug OTG cable and try again."
  exit 1

elif [ "$1" = "--stop" ]; then
  pkill -9 -f python 2>/dev/null
  pkill -9 -f usb_bridge.py 2>/dev/null
  rm -f "$LOG_FILE"
  echo "[+] Bridge process killed. Port 8888 released."
  exit 0

else
  echo "mic-usb: Native USB-to-TCP serial bridge for Termux & PRoot Ubuntu"
  echo ""
  echo "Usage:"
  echo "  mic-usb --start    Start the USB-to-TCP background bridge"
  echo "  mic-usb --stop     Shut down TCP server & kill all bridge processes"
  echo ""
  echo "Upload Guidelines (PRoot Ubuntu):"
  echo "  1. Pass the network port flag to arduino-cli:"
  echo "     --port net:127.0.0.1:8888"
  echo ""
  echo "  2. Full Upload Command:"
  echo "     arduino-cli compile --upload --fqbn arduino:avr:uno --port net:127.0.0.1:8888 <sketch_dir>"
  exit 0
fi
CLIEOF

chmod +x $PREFIX/bin/usb_bridge.py
chmod +x $PREFIX/bin/mic-usb

echo "[+] Installation complete! Run 'mic-usb' to view usage."
