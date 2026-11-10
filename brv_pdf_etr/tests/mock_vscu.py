"""A fake KRA VSCU for testing (same answers shape as the real one)."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"next": 101, "rcpt": 500, "items": {}, "sales": [], "offline": False, "refuse": ""}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        path = self.path.strip("/")
        if STATE["offline"]:
            self.connection.close()
            return
        if path == "initializer/selectInitInfo":
            out = {"resultCd": "000", "resultMsg": "It is succeeded",
                   "data": {"info": {"tin": body["tin"], "taxprNm": "TEST TRADERS LTD", "sdcId": "KRACU0300001234",
                                     "mrcNo": "WIS00012345", "lastSaleInvcNo": STATE["next"] - 1}}}
        elif path == "items/saveItems":
            STATE["items"][body["itemCd"]] = body
            out = {"resultCd": "000", "resultMsg": "It is succeeded", "data": None}
        elif path == "trnsSales/saveSales":
            if STATE["refuse"]:
                out = {"resultCd": "910", "resultMsg": STATE["refuse"], "data": None}
            elif body["invcNo"] != STATE["next"]:
                out = {"resultCd": "921", "resultMsg": "Invoice number is not in sequence. expected invoice number is: %d" % STATE["next"], "data": None}
            else:
                missing = [i["itemCd"] for i in body["itemList"] if i["itemCd"] not in STATE["items"]]
                tot = round(sum(i["totAmt"] for i in body["itemList"]), 2)
                if missing:
                    out = {"resultCd": "930", "resultMsg": "Item not registered: %s" % missing, "data": None}
                elif abs(tot - body["totAmt"]) > 0.001:
                    out = {"resultCd": "931", "resultMsg": "totAmt mismatch", "data": None}
                else:
                    STATE["next"] += 1
                    STATE["rcpt"] += 1
                    STATE["sales"].append(body)
                    out = {"resultCd": "000", "resultMsg": "It is succeeded", "data": {
                        "rcptNo": STATE["rcpt"], "totRcptNo": STATE["rcpt"] + 1000,
                        "intrlData": "WX3QKJ7RZQ2VVK5FBEDD2BCE5Y", "rcptSign": "ABCD1234EFGH5678",
                        "sdcDateTime": "20261030160000", "sdcId": "KRACU0300001234", "mrcNo": "WIS00012345"}}
        else:
            out = {"resultCd": "999", "resultMsg": "unknown path " + path}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def serve(port=18088):
    srv = HTTPServer(("127.0.0.1", port), H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


if __name__ == "__main__":
    serve(int(sys.argv[1]) if len(sys.argv) > 1 else 18088)
    threading.Event().wait()
