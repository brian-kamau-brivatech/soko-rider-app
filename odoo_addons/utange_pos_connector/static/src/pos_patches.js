/** @odoo-module */

import { patch } from "@web/core/utils/patch";
import { _t } from "@web/core/l10n/translation";
import { PosStore } from "@point_of_sale/app/store/pos_store";
import { ClosePosPopup } from "@point_of_sale/app/navbar/closing_popup/closing_popup";
import { PaymentScreen } from "@point_of_sale/app/screens/payment_screen/payment_screen";
import { ErrorPopup } from "@point_of_sale/app/errors/popups/error_popup";
import { UtangeStockPopup } from "@utange_pos_connector/stock_popup";

function errText(e) {
    return (e && e.data && e.data.message) || (e && e.message) || String(e);
}

function isOffline(e) {
    return e && (e.name === "ConnectionLostError" || e.constructor?.name === "ConnectionLostError");
}

patch(PosStore.prototype, {
    utangeIsManager() {
        return this.get_cashier()?.role === "manager";
    },
    utangeApprovalNote(r) {
        if (r && r.approval === "pending") {
            this.env.services.notification.add(
                _t("Stock sheet %s: %s differences sent to the manager for approval.", r.name, r.diffs),
                { type: "warning" }
            );
        } else if (r && r.approval === "approved") {
            this.env.services.notification.add(_t("Stock sheet %s: differences approved, stock corrected.", r.name),
                { type: "success" });
        }
    },
    /** The employee signed in on the POS (Log in with employees), else false. */
    utangeEmployeeId() {
        return this.config.module_pos_hr ? this.get_cashier()?.id || false : false;
    },

    /** Opening stock popup before the shift can be used. Returns false when the cashier went back to Odoo. */
    async utangeOpeningCount() {
        let res;
        try {
            res = await this.orm.call("pos.session", "utange_open_lines", [this.pos_session.id, this.utangeEmployeeId()]);
        } catch (e) {
            if (isOffline(e)) {
                return true;
            }
            throw e;
        }
        if (res.denied) {
            await this.popup.add(ErrorPopup, { title: _t("Not allowed"), body: res.denied });
            this.redirectToBackend();
            return false;
        }
        if (!res.needed) {
            return true;
        }
        for (;;) {
            const { confirmed, payload } = await this.popup.add(UtangeStockPopup, {
                phase: "open",
                lines: res.lines,
                corrects: res.corrects,
                canCancel: true,
                isManager: !!res.can_approve,
                configId: this.config.id,
            });
            if (!confirmed) {
                this.redirectToBackend();
                return false;
            }
            try {
                const r = await this.orm.call("pos.session", "utange_confirm_open", [
                    this.pos_session.id, payload.counts, payload.note, this.utangeEmployeeId(), payload.manager_pin,
                ]);
                this.utangeApprovalNote(r);
                return true;
            } catch (e) {
                await this.popup.add(ErrorPopup, { title: _t("Opening stock not saved"), body: errText(e) });
            }
        }
    },

    async openCashControl() {
        if (this._utangeBusy) {
            return;
        }
        if (this.config.module_pos_hr && !this.hasLoggedIn) {
            return super.openCashControl(...arguments); // after the cashier's PIN (login screen calls again)
        }
        if (!this._utangeOpenDone) {
            this._utangeBusy = true;
            try {
                if (!(await this.utangeOpeningCount())) {
                    return;
                }
                this._utangeOpenDone = true;
            } finally {
                this._utangeBusy = false;
            }
        }
        this.utangeLoadStock();
        return super.openCashControl(...arguments);
    },

    /** {product_id: quantity left} for stock-tracked items (only when "Do not sell items with no stock" is on). */
    async utangeLoadStock() {
        try {
            this.utangeStock = await this.orm.silent.call("pos.config", "utange_pos_stock", [
                this.config.id, this.pos_session.id,
            ]);
        } catch {
            // offline: keep the last figures
        }
    },

    async addProductFromUi(product, options) {
        const stock = this.utangeStock || {};
        const left = stock[String(product.id)];
        if (left !== undefined && !(options && options.quantity < 0)) {
            const order = this.get_order();
            const inCart = (order ? order.get_orderlines() : [])
                .filter((l) => l.product.id === product.id)
                .reduce((s, l) => s + l.get_quantity(), 0);
            const adding = (options && options.quantity) || 1;
            if (inCart + adding > left + 1e-6) {
                await this.popup.add(ErrorPopup, {
                    title: _t("Out of stock"),
                    body: left <= 0
                        ? _t("%s has no stock. Make a requisition from the main store first.", product.display_name)
                        : _t("Only %s of %s left.", left, product.display_name),
                });
                return;
            }
        }
        return super.addProductFromUi(...arguments);
    },
});

patch(PaymentScreen.prototype, {
    async _isOrderValid(isForceValidate) {
        if (!(await super._isOrderValid(...arguments))) {
            return false;
        }
        const lines = this.currentOrder.get_orderlines()
            .map((l) => ({ product_id: l.product.id, qty: l.get_quantity() }))
            .filter((l) => l.qty > 0);
        if (!lines.length) {
            return true;
        }
        let short = [];
        try {
            short = await this.pos.orm.call("pos.config", "utange_check_stock", [
                this.pos.config.id, this.pos.pos_session.id, lines,
            ]);
        } catch (e) {
            if (isOffline(e)) {
                return true; // offline: Odoo checks again when it can
            }
            throw e;
        }
        if (short.length) {
            await this.popup.add(ErrorPopup, {
                title: _t("Not enough stock"),
                body: short.join("\n") + "\n\n" + _t("Remove or reduce these items, or make a requisition first."),
            });
            return false;
        }
        return true;
    },
    async _finalizeValidation() {
        const res = await super._finalizeValidation(...arguments);
        const stock = this.pos.utangeStock;
        if (stock) {
            for (const l of this.currentOrder?.get_orderlines?.() || []) {
                const k = String(l.product.id);
                if (stock[k] !== undefined) {
                    stock[k] -= l.get_quantity();
                }
            }
        }
        return res;
    },
});

patch(ClosePosPopup.prototype, {
    /** Closing stock popup before Odoo closes the session. */
    async utangeClosingCount() {
        if (!(await this.pos.push_orders_with_closing_popup())) {
            return false;
        }
        const res = await this.orm.call("pos.session", "utange_close_lines", [this.pos.pos_session.id, this.pos.utangeEmployeeId()]);
        if (res.denied) {
            await this.popup.add(ErrorPopup, { title: _t("Not allowed"), body: res.denied });
            return false;
        }
        if (!res.needed) {
            return true;
        }
        const { confirmed, payload } = await this.popup.add(UtangeStockPopup, {
            phase: "close",
            lines: res.lines,
            canCancel: true,
            isManager: !!res.can_approve,
            configId: this.pos.config.id,
        });
        if (!confirmed) {
            return false;
        }
        const r = await this.orm.call("pos.session", "utange_confirm_close", [
            this.pos.pos_session.id, payload.counts, payload.note, this.pos.utangeEmployeeId(), payload.manager_pin,
        ]);
        this.pos.utangeApprovalNote(r);
        return true;
    },
    async confirm() {
        try {
            if (!(await this.utangeClosingCount())) {
                return;
            }
        } catch (e) {
            await this.popup.add(ErrorPopup, { title: _t("Closing stock not saved"), body: errText(e) });
            return;
        }
        return super.confirm(...arguments);
    },
});
