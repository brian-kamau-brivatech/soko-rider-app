/** @odoo-module */

import { AbstractAwaitablePopup } from "@point_of_sale/app/popup/abstract_awaitable_popup";
import { useState } from "@odoo/owl";
import { useService } from "@web/core/utils/hooks";

/**
 * Utange stock sheet inside the Odoo POS screen. Every item shows the figure Odoo expects
 * (opening: what Odoo has; closing: opening + in - out - sold). Change any figure that is wrong
 * (e.g. Odoo says 2 sodas, the shelf has 1) and confirm.
 * props: phase ('open'|'close'), lines [{product_id, name, point, uom, ref, ...}], canCancel, corrects
 */
export class UtangeStockPopup extends AbstractAwaitablePopup {
    static template = "utange_pos_connector.UtangeStockPopup";
    static defaultProps = { cancelKey: false, confirmKey: false, canCancel: true, corrects: false, isManager: false };

    setup() {
        super.setup();
        this.orm = useService("orm");
        this.state = useState({
            stage: "count", // count | approve
            pin: "",
            pinError: "",
            busy: false,
            managerPin: "",
            q: "",
            point: "",
            onlyDiff: false,
            note: "",
            rows: (this.props.lines || []).map((l) => ({ ...l, counted: this.fmt(l.ref) })),
        });
    }
    get isOpen() {
        return this.props.phase === "open";
    }
    fmt(n) {
        const v = Math.round((Number(n) || 0) * 1000) / 1000;
        return String(v);
    }
    num(v) {
        const s = String(v ?? "").trim().replace(",", ".");
        if (s === "") {
            return null;
        }
        const n = Number(s);
        return isNaN(n) ? null : n;
    }
    diff(r) {
        const n = this.num(r.counted);
        return n === null ? null : Math.round((n - (Number(r.ref) || 0)) * 1000) / 1000;
    }
    hasDiff(r) {
        const d = this.diff(r);
        return d !== null && Math.abs(d) > 0.0001;
    }
    signed(d) {
        return (d > 0 ? "+" : "") + this.fmt(d);
    }
    get points() {
        return [...new Set(this.state.rows.map((r) => r.point).filter(Boolean))];
    }
    get shown() {
        const q = this.state.q.trim().toLowerCase();
        return this.state.rows.filter(
            (r) =>
                (!q || r.name.toLowerCase().includes(q)) &&
                (!this.state.point || r.point === this.state.point) &&
                (!this.state.onlyDiff || this.hasDiff(r))
        );
    }
    get diffRows() {
        return this.state.rows.filter((r) => this.hasDiff(r));
    }
    get valid() {
        return this.state.rows.every((r) => this.num(r.counted) !== null && this.num(r.counted) >= 0);
    }
    step(r, by) {
        const n = this.num(r.counted) ?? 0;
        r.counted = this.fmt(Math.max(0, n + by));
    }
    reset(r) {
        r.counted = this.fmt(r.ref);
    }
    detail(r) {
        if (this.isOpen) {
            return r.last_close !== null && r.last_close !== undefined ? `last close ${this.fmt(r.last_close)}` : "";
        }
        let s = `open ${this.fmt(r.opening)}`;
        if (r.received) {
            s += ` + in ${this.fmt(r.received)}`;
        }
        if (r.sent_out) {
            s += ` − out ${this.fmt(r.sent_out)}`;
        }
        return s + ` − sold ${this.fmt(r.sold)}`;
    }
    /** Count confirmed: with differences a manager approves (PIN now, or later in the Manager app / Odoo). */
    async confirm() {
        if (!this.valid) {
            return;
        }
        if (this.state.stage === "count" && this.diffRows.length && !this.props.isManager) {
            this.state.stage = "approve";
            return;
        }
        this.state.managerPin = "";
        return super.confirm();
    }
    backToCount() {
        this.state.stage = "count";
        this.state.pinError = "";
    }
    get reasonOk() {
        return this.state.note.trim().length >= 3;
    }
    async approveWithPin() {
        if (!this.reasonOk || !this.state.pin.trim() || this.state.busy) {
            return;
        }
        this.state.busy = true;
        try {
            const r = await this.orm.call("pos.config", "utange_check_manager_pin", [[this.props.configId], this.state.pin.trim()]);
            if (!r.ok) {
                this.state.pinError = r.error || "Wrong manager PIN.";
                return;
            }
            this.state.managerPin = this.state.pin.trim();
            this.props.close({ confirmed: true, payload: await this.getPayload() });
        } finally {
            this.state.busy = false;
        }
    }
    async sendToManager() {
        if (!this.reasonOk) {
            return;
        }
        this.state.managerPin = "";
        this.props.close({ confirmed: true, payload: await this.getPayload() });
    }
    async getPayload() {
        return {
            counts: this.state.rows.map((r) => ({ product_id: r.product_id, qty: this.num(r.counted) })),
            note: this.state.note,
            manager_pin: this.state.managerPin || "",
        };
    }
}
