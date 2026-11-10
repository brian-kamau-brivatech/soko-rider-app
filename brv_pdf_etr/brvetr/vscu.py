"""Talks to the KRA VSCU (same calls as BRV POS)."""
import json
import socket
import time
import urllib.error
import urllib.request


class VscuResult:
    def __init__(self, ok, code="", msg="", data=None, raw=None, no_answer=False):
        self.ok = ok
        self.code = code
        self.msg = msg
        self.data = data or {}
        self.raw = raw
        self.no_answer = no_answer  # network problem: outcome unknown

    @property
    def message(self):
        if self.ok:
            return self.msg or "Successful"
        return "%s: %s" % (self.code, self.msg) if self.code else self.msg

    def __repr__(self):
        return "VscuResult(%s)" % self.message


class Vscu:
    def __init__(self, settings, log=None):
        self.s = settings
        self.log = log  # callable(path, payload, response, ok, code, msg, ms)

    def call(self, path, body, timeout=None):
        payload = {"tin": self.s["tin"], "bhfId": self.s["bhf_id"]}
        payload.update(body)
        url = "%s/%s" % (self.s.root, path)
        if timeout is None:
            timeout = 100 if path.startswith("trnsSales") else 30
        started = time.time()
        try:
            req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"),
                                         headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as r:
                text = r.read().decode("utf-8", "replace")
            try:
                j = json.loads(text)
            except ValueError:
                j = None
            if not isinstance(j, dict):
                res = VscuResult(False, msg="The VSCU did not answer with data.")
            else:
                code = str(j.get("resultCd", ""))
                data = j.get("data") if isinstance(j.get("data"), dict) else {}
                res = VscuResult(code == "000", code, str(j.get("resultMsg", "")), data, j)
        except urllib.error.HTTPError as e:
            res = VscuResult(False, msg="The VSCU answered HTTP %s." % e.code)
        except (socket.timeout, TimeoutError):
            res = VscuResult(False, msg="No answer from the VSCU in time.", no_answer=True)
        except (urllib.error.URLError, OSError):
            res = VscuResult(False, no_answer=True,
                             msg="Cannot reach the VSCU at %s. Check the network and the VSCU address." % self.s.root)
        if self.log:
            try:
                self.log(path, payload, res.raw or {"error": res.msg}, res.ok, res.code, res.msg,
                         int((time.time() - started) * 1000))
            except Exception:
                pass
        return res

    @staticmethod
    def already_installed(res):
        return res.code == "902" or "device is installed" in res.msg.lower() or "already" in res.msg.lower()

    def initialise(self):
        """initializer/selectInitInfo. 902 = this device was already set up (fine)."""
        res = self.call("initializer/selectInitInfo", {"dvcSrlNo": self.s["serial"]})
        if not res.ok and not self.already_installed(res):
            return res, None
        info = res.data.get("info") if isinstance(res.data.get("info"), dict) else {}
        self.s["initialised"] = True
        if info.get("taxprNm"):
            self.s["taxpayer_name"] = str(info["taxprNm"])
        if info.get("sdcId"):
            self.s["sdc_id"] = str(info["sdcId"])
        if info.get("mrcNo"):
            self.s["mrc_no"] = str(info["mrcNo"])
        self.s.save()
        last = info.get("lastSaleInvcNo")
        try:
            last = int(last) if last not in (None, "") else None
        except ValueError:
            last = None
        return res, last

    def save_item(self, item):
        user = self.s.get("user_name") or "BRV PDF ETR"
        return self.call("items/saveItems", {
            "itemCd": item["item_cd"],
            "itemClsCd": item["cls_cd"],
            "itemTyCd": item["item_type"],
            "itemNm": item["name"][:200],
            "orgnNatCd": (item.get("origin") or "KE")[:2].upper(),
            "pkgUnitCd": item["pkg_unit"],
            "qtyUnitCd": item["qty_unit"],
            "taxTyCd": item["tax"],
            "bcd": None,
            "dftPrc": item["price"],
            "isrcAplcbYn": "N",
            "useYn": "Y",
            "regrId": "1", "regrNm": user, "modrId": "1", "modrNm": user,
        })

    def save_sale(self, payload):
        return self.call("trnsSales/saveSales", payload)
