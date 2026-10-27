#!/usr/bin/env python3
"""Minimal FTP server for FileAdmiral's self-tests (standard library only).

Serves ROOT on 127.0.0.1:PORT for user "test" / password "test pass". Supports the commands
curl uses: USER PASS PWD CWD TYPE EPSV PASV MLSD LIST NLST RETR STOR SIZE DELE MKD RMD RNFR RNTO.
Not for real use: single user, no TLS, paths are confined to ROOT.

Usage: test_ftp_server.py ROOT [PORT]
"""
import os
import socket
import sys
import threading
import time

ROOT = os.path.realpath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2121


def local(cwd, arg):
    path = arg if arg.startswith("/") else os.path.join(cwd, arg)
    path = os.path.normpath("/" + path)
    real = os.path.realpath(ROOT + path)
    if real != ROOT and not real.startswith(ROOT + os.sep):
        raise PermissionError("outside root")
    return path, real


def mlsd_line(name, full):
    st = os.lstat(full)
    kind = "dir" if os.path.isdir(full) else "file"
    modify = time.strftime("%Y%m%d%H%M%S", time.gmtime(st.st_mtime))
    return f"type={kind};size={st.st_size};modify={modify};UNIX.mode={oct(st.st_mode & 0o777)[2:]}; {name}\r\n"


def list_line(name, full):
    st = os.lstat(full)
    kind = "d" if os.path.isdir(full) else "-"
    date = time.strftime("%b %d %H:%M", time.localtime(st.st_mtime))
    return f"{kind}rw-r--r--    1 test     test     {st.st_size:>10} {date} {name}\r\n"


class Session(threading.Thread):
    def __init__(self, conn):
        super().__init__(daemon=True)
        self.conn = conn
        self.cwd = "/"
        self.pasv = None
        self.rename_from = None
        self.user = None
        self.logged_in = False

    def send(self, line):
        self.conn.sendall((line + "\r\n").encode())

    def data_conn(self):
        if not self.pasv:
            return None
        self.pasv.settimeout(10)
        c, _ = self.pasv.accept()
        self.pasv.close()
        self.pasv = None
        return c

    def run(self):
        self.send("220 test ftp")
        f = self.conn.makefile("rb")
        while True:
            raw = f.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            cmd, _, arg = line.partition(" ")
            cmd = cmd.upper()
            try:
                if not self.handle(cmd, arg):
                    break
            except PermissionError:
                self.send("550 Permission denied")
            except FileNotFoundError:
                self.send("550 No such file or directory")
            except OSError as e:
                self.send(f"550 {e.strerror or e}")
        self.conn.close()

    def handle(self, cmd, arg):
        if cmd == "USER":
            self.user = arg
            self.send("331 Password required")
        elif cmd == "PASS":
            self.logged_in = self.user == "test" and arg == "test pass"
            self.send("230 Logged in" if self.logged_in else "530 Login incorrect")
        elif not self.logged_in and cmd not in ("QUIT",):
            self.send("530 Please login")
        elif cmd == "PWD":
            self.send(f'257 "{self.cwd}" is the current directory')
        elif cmd == "CWD":
            path, real = local(self.cwd, arg)
            if not os.path.isdir(real):
                raise FileNotFoundError
            self.cwd = path
            self.send("250 OK")
        elif cmd == "TYPE":
            self.send("200 OK")
        elif cmd in ("EPSV", "PASV"):
            self.pasv = socket.socket()
            self.pasv.bind(("127.0.0.1", 0))
            self.pasv.listen(1)
            port = self.pasv.getsockname()[1]
            if cmd == "EPSV":
                self.send(f"229 Entering Extended Passive Mode (|||{port}|)")
            else:
                self.send(f"227 Entering Passive Mode (127,0,0,1,{port >> 8},{port & 255})")
        elif cmd in ("MLSD", "LIST", "NLST"):
            _, real = local(self.cwd, arg or ".")
            self.send("150 Listing")
            c = self.data_conn()
            for name in sorted(os.listdir(real)):
                full = os.path.join(real, name)
                text = mlsd_line(name, full) if cmd == "MLSD" else (list_line(name, full) if cmd == "LIST" else name + "\r\n")
                c.sendall(text.encode())
            c.close()
            self.send("226 Done")
        elif cmd == "SIZE":
            _, real = local(self.cwd, arg)
            self.send(f"213 {os.path.getsize(real)}")
        elif cmd == "RETR":
            _, real = local(self.cwd, arg)
            with open(real, "rb") as fh:
                self.send("150 Sending")
                c = self.data_conn()
                c.sendall(fh.read())
                c.close()
            self.send("226 Done")
        elif cmd == "STOR":
            _, real = local(self.cwd, arg)
            self.send("150 Receiving")
            c = self.data_conn()
            with open(real, "wb") as fh:
                while True:
                    chunk = c.recv(65536)
                    if not chunk:
                        break
                    fh.write(chunk)
            c.close()
            self.send("226 Done")
        elif cmd == "DELE":
            os.remove(local(self.cwd, arg)[1])
            self.send("250 Deleted")
        elif cmd == "MKD":
            path, real = local(self.cwd, arg)
            os.mkdir(real)
            self.send(f'257 "{path}" created')
        elif cmd == "RMD":
            os.rmdir(local(self.cwd, arg)[1])
            self.send("250 Removed")
        elif cmd == "RNFR":
            self.rename_from = local(self.cwd, arg)[1]
            self.send("350 Ready")
        elif cmd == "RNTO":
            os.rename(self.rename_from, local(self.cwd, arg)[1])
            self.send("250 Renamed")
        elif cmd == "QUIT":
            self.send("221 Bye")
            return False
        elif cmd in ("OPTS", "FEAT"):
            self.send("211 No features" if cmd == "FEAT" else "200 OK")
        else:
            self.send("502 Not implemented")
        return True


def main():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(5)
    print(f"FTP test server on 127.0.0.1:{PORT} serving {ROOT}", flush=True)
    while True:
        conn, _ = srv.accept()
        Session(conn).start()


if __name__ == "__main__":
    main()
