// Drag-and-drop cart with a custom pointer-driven ghost. Sources
// are either product cards in the feed (`.card[data-product]`) or
// cart items already in the pane (`.cart-item[data-product]` —
// which carry an extra `data-from-slot` attribute so the drop
// handler can move them out of their origin slot).
//
// State (persisted as JSON under STORAGE_KEY):
//
//   slots: [
//     { products: [{id, name, brand, image_url, prices}] },   // single
//     { products: [{...}, {...}] }                            // group (2+)
//   ]
//
// `Cart` is a Phoenix LiveView hook attached to `<aside id="cart">`.

const STORAGE_KEY = "super_barato.cart.v1"
const DRAG_THRESHOLD = 5

const Store = {
  load() {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY)
      const parsed = raw ? JSON.parse(raw) : []
      return Array.isArray(parsed) ? parsed : []
    } catch (_e) { return [] }
  },
  save(slots) {
    try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(slots)) } catch (_e) {}
  },
}

const escHtml = (s) => {
  const d = document.createElement("div")
  d.textContent = s == null ? "" : String(s)
  return d.innerHTML
}

const formatClp = (n) => {
  if (n == null) return "—"
  return "$" + Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
}

// Cheapest effective price per chain → either a single value or a
// `{lo, hi}` tuple when the product spans multiple chains at
// different price points.
const priceSummary = (prices) => {
  if (!Array.isArray(prices) || prices.length === 0) return {kind: "none"}
  const eff = prices
    .filter((r) => Number.isFinite(r.price))
    .map((r) => r.price)
  if (eff.length === 0) return {kind: "none"}
  const lo = Math.min(...eff)
  const hi = Math.max(...eff)
  return lo === hi ? {kind: "single", value: lo} : {kind: "range", lo, hi}
}

// Word-level token extraction used to find the shared term across a
// comparison group's product names. Matches the spirit of the
// server-side popular_terms tokenizer: lowercase, strip punctuation,
// drop short/stop/unit words and pure numbers.
const STOP_WORDS = new Set([
  "de", "la", "el", "en", "y", "con", "sin", "los", "las", "del", "al",
  "por", "para", "su", "sus", "a", "un", "una", "uno", "mas",
])
const UNIT_WORDS = new Set([
  "g", "kg", "mg", "ml", "cl", "cc", "lt", "l", "un", "mt", "cm", "km",
  "oz", "lb", "lbs", "pack", "pcs", "unid", "uns",
])

const tokenize = (text) => {
  if (!text) return []
  return String(text)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .split(/\s+/u)
    .filter((t) => t.length >= 3 && !STOP_WORDS.has(t) && !UNIT_WORDS.has(t) && !/^\d+$/.test(t))
}

// First token (longest first) shared by *every* product in the
// group — used as the group label when there is one. Returns null
// when no shared word qualifies.
const commonWord = (products) => {
  if (!Array.isArray(products) || products.length < 2) return null
  const tokenSets = products.map((p) => new Set(tokenize(p.name)))
  if (tokenSets.some((s) => s.size === 0)) return null
  const first = [...tokenSets[0]]
  // Prefer longer words — they're more specific.
  first.sort((a, b) => b.length - a.length)
  for (const word of first) {
    if (tokenSets.every((s) => s.has(word))) {
      return word.charAt(0).toUpperCase() + word.slice(1)
    }
  }
  return null
}

const renderPrice = (prices) => {
  const s = priceSummary(prices)
  if (s.kind === "none") return `<span class="cart-item__price cart-item__price--empty">—</span>`
  if (s.kind === "single") return `<span class="cart-item__price">${formatClp(s.value)}</span>`
  return `<span class="cart-item__price"><span class="cart-item__price-lo">${formatClp(s.lo)}</span><span class="cart-item__price-dash">–</span><span class="cart-item__price-hi">${formatClp(s.hi)}</span></span>`
}

// ── Cart hook ─────────────────────────────────────────────────────

export const Cart = {
  mounted() {
    this.slots = Store.load().map((slot) => ({
      products: (slot.products || []).map((p) => ({...p, qty: p.qty || 1})),
    }))
    this.body = this.el.querySelector("[data-cart-body]")
    this.footer = this.el.querySelector("[data-cart-footer]")

    this._onAdd = (e) => this.add(e.detail.product, e.detail.target)
    this._onMove = (e) => this.move(e.detail)
    this._onClick = (e) => {
      const removeBtn = e.target.closest("[data-remove-product]")
      if (removeBtn) {
        const slotEl = removeBtn.closest("[data-slot-idx]")
        if (!slotEl) return
        this.remove(parseInt(slotEl.dataset.slotIdx, 10), parseInt(removeBtn.dataset.removeProduct, 10))
        return
      }
      const qtyBtn = e.target.closest("[data-qty]")
      if (qtyBtn) {
        const slotEl = qtyBtn.closest("[data-slot-idx]")
        if (!slotEl) return
        this.changeQty(
          parseInt(slotEl.dataset.slotIdx, 10),
          parseInt(qtyBtn.dataset.productIdx, 10),
          qtyBtn.dataset.qty === "inc" ? 1 : -1,
        )
        return
      }
      const toggleBtn = e.target.closest("[data-toggle-slot]")
      if (toggleBtn) {
        this.toggleCollapsed(parseInt(toggleBtn.dataset.toggleSlot, 10))
        return
      }
    }

    this._onLabelKey = (e) => {
      const labelEl = e.target.closest("[data-slot-label]")
      if (!labelEl) return
      if (e.key === "Enter") { e.preventDefault(); labelEl.blur() }
      if (e.key === "Escape") { labelEl.textContent = labelEl.dataset.savedLabel || ""; labelEl.blur() }
    }
    this._onLabelFocus = (e) => {
      const labelEl = e.target.closest("[data-slot-label]")
      if (!labelEl) return
      // Stash the on-focus value so Escape can revert.
      labelEl.dataset.savedLabel = labelEl.textContent.trim()
      // Stop drag-from-label.
      labelEl.draggable = false
    }
    this._onLabelBlur = (e) => {
      const labelEl = e.target.closest("[data-slot-label]")
      if (!labelEl) return
      const slotIdx = parseInt(labelEl.dataset.slotLabel, 10)
      const value = labelEl.textContent.trim()
      const auto = labelEl.dataset.defaultLabel || ""
      const slot = this.slots[slotIdx]
      if (!slot) return
      // Treat empty input or input matching auto-label as "no manual label".
      if (value === "" || value === auto) {
        delete slot.label
      } else {
        slot.label = value
      }
      Store.save(this.slots)
      // Restore display text (just in case the user typed/deleted).
      labelEl.textContent = (slot.label && slot.label.trim()) || auto
    }

    this.el.addEventListener("cart:add", this._onAdd)
    this.el.addEventListener("cart:move", this._onMove)
    this.el.addEventListener("click", this._onClick)
    this.el.addEventListener("keydown", this._onLabelKey)
    this.el.addEventListener("focusin", this._onLabelFocus)
    this.el.addEventListener("focusout", this._onLabelBlur)
    this.render({animate: false})
  },

  destroyed() {
    this.el.removeEventListener("cart:add", this._onAdd)
    this.el.removeEventListener("cart:move", this._onMove)
    this.el.removeEventListener("click", this._onClick)
    this.el.removeEventListener("keydown", this._onLabelKey)
    this.el.removeEventListener("focusin", this._onLabelFocus)
    this.el.removeEventListener("focusout", this._onLabelBlur)
  },

  add(product, target) {
    const entry = {...product, qty: 1}
    if (!target || target.kind === "pane") {
      this.slots.push({products: [entry]})
    } else if (target.kind === "slot") {
      const slot = this.slots[target.slotIdx]
      if (slot) slot.products.push(entry)
      else this.slots.push({products: [entry]})
    }
    Store.save(this.slots)
    this.render({animate: true, focusSlotIdx: target?.slotIdx})
  },

  changeQty(slotIdx, productIdx, delta) {
    const slot = this.slots[slotIdx]
    if (!slot) return
    const p = slot.products[productIdx]
    if (!p) return
    const next = (p.qty || 1) + delta
    if (next <= 0) {
      this.remove(slotIdx, productIdx)
      return
    }
    p.qty = next
    Store.save(this.slots)
    // Lightweight DOM update so we don't re-render (and lose hover) on every click.
    const el = this.body.querySelector(
      `[data-slot-idx="${slotIdx}"] [data-qty-display="${productIdx}"]`,
    )
    if (el) el.textContent = next
    this._updateBadge()
    this._renderFooter()
  },

  // Move a product already in the cart to a different slot (or split
  // it out into a new single slot when dropped on the pane).
  move({fromSlotIdx, fromProductIdx, target}) {
    const from = this.slots[fromSlotIdx]
    if (!from) return
    const product = from.products[fromProductIdx]
    if (!product) return
    // Dropping back on the same slot is a no-op.
    if (target.kind === "slot" && target.slotIdx === fromSlotIdx) return

    from.products.splice(fromProductIdx, 1)
    const originRemoved = from.products.length === 0
    if (originRemoved) this.slots.splice(fromSlotIdx, 1)

    let tIdx = target.kind === "slot" ? target.slotIdx : null
    if (originRemoved && tIdx != null && tIdx > fromSlotIdx) tIdx -= 1

    if (target.kind === "pane") {
      this.slots.push({products: [product]})
    } else {
      this.slots[tIdx].products.push(product)
    }

    Store.save(this.slots)
    this.render({animate: true, focusSlotIdx: tIdx ?? this.slots.length - 1})
  },

  toggleCollapsed(slotIdx) {
    const slot = this.slots[slotIdx]
    if (!slot) return
    slot.collapsed = !slot.collapsed
    Store.save(this.slots)
    const slotEl = this.body.querySelector(`[data-slot-idx="${slotIdx}"]`)
    if (slotEl) slotEl.classList.toggle("cart-slot--collapsed", !!slot.collapsed)
  },

  remove(slotIdx, productIdx) {
    const slot = this.slots[slotIdx]
    if (!slot) return
    slot.products.splice(productIdx, 1)
    if (slot.products.length === 0) this.slots.splice(slotIdx, 1)
    Store.save(this.slots)
    this.render({animate: true})
  },

  render({animate = false, focusSlotIdx = null} = {}) {
    const prevRects = animate ? this._captureRects() : null

    if (this.slots.length === 0) {
      this.body.innerHTML = `
        <div class="cart-empty">
          <div class="msg">Aún no hay productos</div>
          <div class="hint">Arrastra productos aquí</div>
        </div>
      `
      if (this.footer) {
        this.footer.innerHTML = ""
        this.footer.hidden = true
      }
    } else {
      this.body.innerHTML = this.slots.map((slot, idx) => this._renderSlot(slot, idx)).join("")
      this._renderFooter()
    }

    this._updateBadge()
    if (prevRects) this._playFlip(prevRects, focusSlotIdx)
  },

  _renderFooter() {
    if (!this.footer) return
    const {min, max} = this._computeTotals()
    const savings = Math.max(0, max - min)
    this.footer.innerHTML = `
      <div class="cart-footer__totals">
        <span class="cart-footer__label">Total</span>
        <span class="cart-footer__amount">
          <span class="cart-footer__lo">${formatClp(min)}</span>
          <span class="cart-footer__dash">–</span>
          <span class="cart-footer__hi">${formatClp(max)}</span>
        </span>
        ${savings > 0 ? `<span class="cart-footer__savings">Ahorra hasta <strong>${formatClp(savings)}</strong></span>` : ""}
      </div>
      <button type="button" class="cart-footer__cta"><span><span class="cart-footer__cta-line">Compra</span><span class="cart-footer__cta-line">Inteligente</span></span></button>
    `
    this.footer.hidden = false
  },

  // Total min/max across the cart. Comparison groups count once
  // (assuming the user picks a single product from the group), so
  // we take the cheapest min and the most expensive max within
  // each group's products. Singles use their own min/max × qty.
  _computeTotals() {
    let min = 0
    let max = 0
    for (const slot of this.slots) {
      const perProduct = slot.products.map((p) => {
        const eff = (p.prices || []).map((r) => r.price).filter(Number.isFinite)
        const qty = p.qty || 1
        if (eff.length === 0) return {min: 0, max: 0}
        return {min: Math.min(...eff) * qty, max: Math.max(...eff) * qty}
      })
      if (slot.products.length > 1) {
        min += Math.min(...perProduct.map((p) => p.min))
        max += Math.max(...perProduct.map((p) => p.max))
      } else {
        min += perProduct[0].min
        max += perProduct[0].max
      }
    }
    return {min, max}
  },

  _updateBadge() {
    const badge = document.querySelector("[data-cart-badge]")
    if (!badge) return
    const total = this.slots.reduce(
      (s, slot) => s + slot.products.reduce((ss, p) => ss + (p.qty || 1), 0),
      0,
    )
    if (total > 0) {
      badge.textContent = total
      badge.removeAttribute("hidden")
    } else {
      badge.textContent = ""
      badge.setAttribute("hidden", "")
    }
  },

  _renderSlot(slot, slotIdx) {
    const isGroup = slot.products.length > 1
    const items = slot.products.map((p, pIdx) => {
      const qty = p.qty || 1
      return `
        <div class="cart-item"
             data-product='${escHtml(JSON.stringify(p))}'
             data-from-slot="${slotIdx}"
             data-from-product="${pIdx}">
          <div class="cart-item__img">
            ${p.image_url ? `<img src="${escHtml(p.image_url)}" alt=""/>` : `<div class="cart-item__placeholder"></div>`}
          </div>
          <div class="cart-item__meta">
            <div class="cart-item__name">${escHtml(p.name)}</div>
            <div class="cart-item__row">
              ${renderPrice(p.prices)}
              <div class="cart-item__qty" role="group" aria-label="Cantidad">
                <button type="button" data-qty="dec" data-product-idx="${pIdx}" aria-label="Quitar uno">−</button>
                <span data-qty-display="${pIdx}">${qty}</span>
                <button type="button" data-qty="inc" data-product-idx="${pIdx}" aria-label="Agregar uno">+</button>
              </div>
            </div>
          </div>
          <button type="button" class="cart-item__remove" data-remove-product="${pIdx}" aria-label="Quitar">×</button>
        </div>
      `
    }).join("")
    const collapsed = isGroup && slot.collapsed
    const groupCls = isGroup ? " cart-slot--group" : ""
    const collapsedCls = collapsed ? " cart-slot--collapsed" : ""
    const autoLabel = isGroup ? (commonWord(slot.products) || "Comparación") : ""
    const groupLabel = (slot.label && slot.label.trim()) || autoLabel
    const header = isGroup
      ? `
        <div class="cart-slot__hd">
          <span class="cart-slot__label"
                contenteditable="plaintext-only"
                spellcheck="false"
                data-slot-label="${slotIdx}"
                data-default-label="${escHtml(autoLabel)}"
                title="Click para renombrar">${escHtml(groupLabel)}</span>
          <span class="cart-slot__count">· ${slot.products.length}</span>
          <button type="button" class="cart-slot__toggle" data-toggle-slot="${slotIdx}"
                  aria-label="${collapsed ? "Expandir" : "Contraer"}" aria-expanded="${!collapsed}">
            <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
                 stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <polyline points="6 9 12 15 18 9"/>
            </svg>
          </button>
        </div>`
      : ""
    return `
      <div class="cart-slot${groupCls}${collapsedCls}" data-slot-idx="${slotIdx}">
        ${header}
        <div class="cart-slot__items">${items}</div>
      </div>
    `
  },

  // FLIP — record old positions, re-render, animate from old → new.
  _captureRects() {
    const rects = new Map()
    this.body.querySelectorAll("[data-slot-idx]").forEach((el) => {
      rects.set(el.dataset.slotIdx, el.getBoundingClientRect())
    })
    return rects
  },

  _playFlip(prevRects, focusSlotIdx) {
    this.body.querySelectorAll("[data-slot-idx]").forEach((el) => {
      const idx = el.dataset.slotIdx
      const prev = prevRects.get(idx)
      const next = el.getBoundingClientRect()
      if (!prev) {
        el.animate([
          {transform: "translateY(-8px) scale(0.92)", opacity: 0},
          {transform: "translateY(0) scale(1)", opacity: 1},
        ], {duration: 260, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)"})
      } else {
        const dx = prev.left - next.left
        const dy = prev.top - next.top
        if (dx !== 0 || dy !== 0) {
          el.animate([
            {transform: `translate(${dx}px, ${dy}px)`},
            {transform: "translate(0, 0)"},
          ], {duration: 220, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)"})
        }
      }
      if (focusSlotIdx != null && parseInt(idx, 10) === focusSlotIdx) {
        el.animate([
          {transform: "scale(1)", boxShadow: "0 0 0 0 rgba(0,0,0,0)"},
          {transform: "scale(1.04)", boxShadow: "0 0 0 4px color-mix(in oklch, oklch(0.78 0.18 80) 30%, transparent)"},
          {transform: "scale(1)", boxShadow: "0 0 0 0 rgba(0,0,0,0)"},
        ], {duration: 360, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)"})
      }
    })
  },
}

// ── DragManager (custom pointer-events DnD) ────────────────────────

const DragManager = {
  active: false,
  pointerId: null,
  product: null,
  source: null,           // "card" | "item"
  originSlotIdx: null,
  originProductIdx: null,
  sourceEl: null,
  startX: 0, startY: 0,
  ghost: null,
  ghostOffsetX: 0, ghostOffsetY: 0,
  target: null,

  init() {
    document.addEventListener("pointerdown", this._onDown.bind(this))
  },

  _onDown(e) {
    if (e.button !== 0) return
    if (e.target.closest("a, button, [data-picker-toggle], input, textarea")) return

    const cardEl = e.target.closest(".card[data-product]")
    const itemEl = e.target.closest(".cart-item[data-product]")
    const sourceEl = itemEl || cardEl
    if (!sourceEl) return

    let product
    try { product = JSON.parse(sourceEl.dataset.product) } catch (_e) { return }

    this.product = product
    this.sourceEl = sourceEl
    this.source = itemEl ? "item" : "card"
    if (itemEl) {
      this.originSlotIdx = parseInt(itemEl.dataset.fromSlot, 10)
      this.originProductIdx = parseInt(itemEl.dataset.fromProduct, 10)
    } else {
      this.originSlotIdx = null
      this.originProductIdx = null
    }

    this.startX = e.clientX
    this.startY = e.clientY
    this.pointerId = e.pointerId
    this.active = false

    this._move = this._onMove.bind(this)
    this._up = this._onUp.bind(this)
    document.addEventListener("pointermove", this._move)
    document.addEventListener("pointerup", this._up)
    document.addEventListener("pointercancel", this._up)
  },

  _onMove(e) {
    if (!this.active) {
      if (Math.hypot(e.clientX - this.startX, e.clientY - this.startY) < DRAG_THRESHOLD) return
      this._begin()
    }
    const x = e.clientX - this.ghostOffsetX
    const y = e.clientY - this.ghostOffsetY
    this.ghost.style.transform = `translate3d(${x}px, ${y}px, 0) rotate(-3deg)`
    this._updateTarget(e.clientX, e.clientY)
  },

  _begin() {
    this.active = true
    document.body.classList.add("is-dragging")
    this.sourceEl.classList.add(this.source === "item" ? "cart-item--dragging" : "card--dragging")

    const ghost = document.createElement("div")
    ghost.className = "drag-ghost"
    ghost.innerHTML = `
      <div class="drag-ghost__img">
        ${this.product.image_url ? `<img src="${escHtml(this.product.image_url)}" alt=""/>` : ""}
      </div>
      <div class="drag-ghost__body">
        <div class="drag-ghost__name">${escHtml(this.product.name)}</div>
        ${this.product.brand ? `<div class="drag-ghost__brand">${escHtml(this.product.brand)}</div>` : ""}
      </div>
    `
    document.body.appendChild(ghost)
    this.ghost = ghost

    const rect = ghost.getBoundingClientRect()
    this.ghostOffsetX = rect.width / 2
    this.ghostOffsetY = rect.height / 2

    this.ghost.style.transform =
      `translate3d(${this.startX - this.ghostOffsetX}px, ${this.startY - this.ghostOffsetY}px, 0) rotate(-3deg)`

    ghost.animate([
      {transform: this.ghost.style.transform.replace("rotate(-3deg)", "rotate(0deg) scale(0.85)"), opacity: 0.4},
      {transform: this.ghost.style.transform, opacity: 1},
    ], {duration: 140, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)"})
  },

  _updateTarget(x, y) {
    const el = document.elementFromPoint(x, y)
    const cartPane = el?.closest(".cart-pane")
    let next = null
    if (cartPane) {
      const slot = el.closest("[data-slot-idx]")
      if (slot) {
        next = {kind: "slot", slotIdx: parseInt(slot.dataset.slotIdx, 10), element: slot, pane: cartPane}
      } else {
        next = {kind: "pane", element: cartPane, pane: cartPane}
      }
    }
    this._setTarget(next)
  },

  _setTarget(next) {
    const prev = this.target
    if (prev?.element === next?.element && prev?.kind === next?.kind) return
    if (prev?.element) {
      prev.element.classList.remove("drop-target")
      if (prev.kind === "slot") prev.element.classList.remove("drop-target--slot")
    }
    if (prev?.pane && (!next || prev.pane !== next.pane)) {
      prev.pane.classList.remove("drop-target--pane")
    }
    if (next?.pane) next.pane.classList.add("drop-target--pane")
    if (next?.element) {
      next.element.classList.add("drop-target")
      if (next.kind === "slot") next.element.classList.add("drop-target--slot")
    }
    this.target = next
  },

  _onUp(e) {
    document.removeEventListener("pointermove", this._move)
    document.removeEventListener("pointerup", this._up)
    document.removeEventListener("pointercancel", this._up)
    if (this.active) this._handleDrop(e.clientX, e.clientY)
    this._cleanup()
  },

  _handleDrop(x, y) {
    if (!this.target) {
      this._fadeGhost()
      return
    }
    // Dropping a cart-item back on its own slot: no-op.
    if (this.source === "item" &&
        this.target.kind === "slot" &&
        this.target.slotIdx === this.originSlotIdx) {
      this._fadeGhost()
      return
    }

    const cartPane = document.querySelector(".cart-pane")
    if (!cartPane) return

    const tRect = this.target.element.getBoundingClientRect()
    const cx = tRect.left + tRect.width / 2 - this.ghostOffsetX
    const cy = tRect.top + tRect.height / 2 - this.ghostOffsetY

    const detail = this.source === "item"
      ? {fromSlotIdx: this.originSlotIdx, fromProductIdx: this.originProductIdx, target: this.target}
      : {product: this.product, target: this.target}
    const eventName = this.source === "item" ? "cart:move" : "cart:add"

    if (this.ghost) {
      const anim = this.ghost.animate([
        {transform: this.ghost.style.transform},
        {transform: `translate3d(${cx}px, ${cy}px, 0) rotate(0deg) scale(0.5)`, opacity: 0},
      ], {duration: 200, easing: "cubic-bezier(0.4, 0, 0.2, 1)"})
      anim.onfinish = () => cartPane.dispatchEvent(new CustomEvent(eventName, {detail}))
    } else {
      cartPane.dispatchEvent(new CustomEvent(eventName, {detail}))
    }
  },

  _fadeGhost() {
    if (!this.ghost) return
    this.ghost.animate([{opacity: 1}, {opacity: 0}], {duration: 120}).onfinish = () => {}
  },

  _cleanup() {
    if (this.ghost) {
      const g = this.ghost
      setTimeout(() => g.remove(), 240)
      this.ghost = null
    }
    if (this.sourceEl) {
      this.sourceEl.classList.remove("card--dragging", "cart-item--dragging")
    }
    if (this.target?.element) {
      this.target.element.classList.remove("drop-target", "drop-target--slot")
    }
    if (this.target?.pane) this.target.pane.classList.remove("drop-target--pane")
    document.body.classList.remove("is-dragging")
    this.active = false
    this.product = null
    this.source = null
    this.sourceEl = null
    this.originSlotIdx = null
    this.originProductIdx = null
    this.target = null
  },
}

DragManager.init()
