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
      if (e.target.closest(".cart-footer__cta")) {
        this.openSmart()
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
    let focusSlotIdx
    let scrollToBottom = false
    if (!target || target.kind === "pane") {
      this.slots.push({products: [entry]})
      focusSlotIdx = this.slots.length - 1
      scrollToBottom = true
    } else if (target.kind === "slot") {
      const slot = this.slots[target.slotIdx]
      if (slot) {
        slot.products.push(entry)
        focusSlotIdx = target.slotIdx
        // Also bottom-scroll when merging into the last slot — the
        // newly-added product sits at the end and the cart's
        // generous bottom padding can hide it otherwise.
        if (target.slotIdx === this.slots.length - 1) scrollToBottom = true
      } else {
        this.slots.push({products: [entry]})
        focusSlotIdx = this.slots.length - 1
        scrollToBottom = true
      }
    }
    Store.save(this.slots)
    this.render({animate: true, focusSlotIdx, scrollToBottom})
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

  openSmart() {
    if (document.querySelector(".smart-cart")) return
    SmartCart.open(this)
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

  render({animate = false, focusSlotIdx = null, scrollToBottom = false} = {}) {
    const prevRects = animate ? this._captureRects() : null

    if (this.slots.length === 0) {
      this.body.innerHTML = `
        <div class="cart-empty">
          <div class="cart-empty__card">
            <div class="cart-empty__glyph cart-empty__glyph--drop" aria-hidden="true">
              <span class="cart-empty__slot"></span>
              <span class="cart-empty__drop-chip"></span>
              <svg class="cart-empty__cursor" viewBox="0 0 24 24"
                   fill="currentColor" stroke="var(--surface)" stroke-width="1.2"
                   stroke-linejoin="round">
                <path d="M5 3 L5 19 L9.5 14.5 L12.5 20 L15 19 L12 13.5 L17 13.5 Z"/>
              </svg>
            </div>
            <div class="cart-empty__text">Arrastra tus productos acá.</div>
          </div>
          <div class="cart-empty__card">
            <div class="cart-empty__glyph cart-empty__glyph--stack" aria-hidden="true">
              <span class="cart-empty__chip"></span>
              <span class="cart-empty__chip"></span>
            </div>
            <div class="cart-empty__text">Suéltalo encima de otro producto para compararlos.</div>
          </div>
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

    // After a new slot was appended, scroll the cart-body all the
    // way to the bottom so the user sees the new item and the empty
    // drop area below it. For merges/moves, just nudge the affected
    // slot into view if it isn't already.
    if (scrollToBottom) {
      this.body.scrollTo({top: this.body.scrollHeight, behavior: "smooth"})
    } else if (focusSlotIdx != null) {
      const el = this.body.querySelector(`[data-slot-idx="${focusSlotIdx}"]`)
      if (el && el.scrollIntoView) {
        el.scrollIntoView({block: "nearest", behavior: "smooth"})
      }
    }
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

// ── Compra Inteligente popover ────────────────────────────────────

const CHAIN_ORDER = ["jumbo", "santa_isabel", "unimarc", "lider", "tottus", "acuenta"]
const CHAIN_NAMES = {
  jumbo: "Jumbo", santa_isabel: "Santa Isabel", unimarc: "Unimarc",
  lider: "Líder", tottus: "Tottus", acuenta: "Acuenta",
}
const CHAIN_ICONS = {
  jumbo: "/images/chains/jumbo.png",
  santa_isabel: "/images/chains/santa_isabel.png",
  unimarc: "/images/chains/unimarc.ico",
  lider: "/images/chains/lider.ico",
  tottus: "/images/chains/tottus.png",
  acuenta: "/images/chains/acuenta.ico",
}

// Cheapest selected-chain price for a product. Returns
// {chain, price} or null if none available.
const bestChainFor = (product, selectedChains) => {
  let best = null
  for (const r of (product.prices || [])) {
    if (!selectedChains.has(r.chain)) continue
    if (!Number.isFinite(r.price)) continue
    if (!best || r.price < best.price) best = {chain: r.chain, price: r.price}
  }
  return best
}

// For a comparison group: among the (non-disabled) products, find
// the (productId, chain, unit price) with the lowest qty-weighted
// cost across selected chains. Returns null if nothing's available.
const bestGroupPick = (slot, selectedChains, disabled) => {
  let best = null
  for (const p of slot.products) {
    if (disabled.has(p.id)) continue
    const w = bestChainFor(p, selectedChains)
    if (!w) continue
    const qty = p.qty || 1
    const cost = w.price * qty
    if (!best || cost < best.cost) {
      best = {productId: p.id, chain: w.chain, price: w.price, qty, cost}
    }
  }
  return best
}

const SmartCart = {
  open(cart) {
    const state = {
      selected: new Set(),                            // populated lazily on first render
      disabled: new Set(),                            // disabled product rows (by id)
      _seeded: false,
    }

    const overlay = document.createElement("div")
    overlay.className = "smart-cart"
    overlay.innerHTML = `
      <div class="smart-cart__backdrop" data-smart-close></div>
      <div class="smart-cart__panel" role="dialog" aria-modal="true">
        <button class="smart-cart__close" type="button" aria-label="Cerrar" data-smart-close>×</button>
        <div class="smart-cart__body" data-table-host></div>
      </div>
    `

    document.body.appendChild(overlay)
    document.body.classList.add("smart-cart-open")

    const tableHost = overlay.querySelector("[data-table-host]")

    const buildContext = () => {
      const allChains = new Set()
      for (const slot of cart.slots) {
        for (const p of slot.products) {
          for (const r of (p.prices || [])) {
            if (Number.isFinite(r.price)) allChains.add(r.chain)
          }
        }
      }
      const chains = CHAIN_ORDER.filter((c) => allChains.has(c))
      if (!state._seeded) {
        state.selected = new Set(chains)
        state._seeded = true
      }
      const items = []
      cart.slots.forEach((slot, slotIdx) => {
        const isGroup = slot.products.length > 1
        const groupLabel = isGroup
          ? (slot.label?.trim() || commonWord(slot.products) || "Comparación")
          : null
        slot.products.forEach((p, pIdx) => {
          items.push({
            slotIdx, pIdx, isGroup, groupLabel,
            isFirstInGroup: isGroup && pIdx === 0,
            isLastInGroup: isGroup && pIdx === slot.products.length - 1,
            product: p,
          })
        })
      })
      return {chains, items}
    }

    const renderTable = () => {
      if (cart.slots.length === 0) { closeIt(); return }
      const {chains, items} = buildContext()
      tableHost.innerHTML = SmartCart._renderTable(items, chains, state)
    }

    overlay.addEventListener("click", (e) => {
      if (e.target.closest("[data-smart-close]")) { closeIt(); return }

      const chainBox = e.target.closest("input[data-chain]")
      if (chainBox) {
        const chain = chainBox.dataset.chain
        if (chainBox.checked) state.selected.add(chain)
        else state.selected.delete(chain)
        renderTable()
        return
      }

      const productBox = e.target.closest("input[data-product-toggle]")
      if (productBox) {
        const id = productBox.dataset.productToggle
        if (productBox.checked) state.disabled.delete(id)
        else state.disabled.add(id)
        renderTable()
        return
      }

      const removeBtn = e.target.closest("[data-smart-remove]")
      if (removeBtn) {
        const slotIdx = parseInt(removeBtn.dataset.smartRemove, 10)
        const pIdx = parseInt(removeBtn.dataset.smartRemoveProduct, 10)
        cart.remove(slotIdx, pIdx)
        renderTable()
        return
      }

      const detailBtn = e.target.closest("[data-product-detail]")
      if (detailBtn) {
        const slotIdx = parseInt(detailBtn.dataset.slotIdx, 10)
        const pIdx = parseInt(detailBtn.dataset.productIdx, 10)
        const slot = cart.slots[slotIdx]
        const p = slot && slot.products[pIdx]
        if (p) ProductDetail.open(p, cart)
        return
      }

      const qtyBtn = e.target.closest("[data-smart-qty]")
      if (qtyBtn) {
        const slotIdx = parseInt(qtyBtn.dataset.smartQtySlot, 10)
        const pIdx = parseInt(qtyBtn.dataset.smartQtyProduct, 10)
        const delta = qtyBtn.dataset.smartQty === "inc" ? 1 : -1
        cart.changeQty(slotIdx, pIdx, delta)
        renderTable()
        return
      }
    })

    const onKey = (e) => { if (e.key === "Escape") closeIt() }
    const closeIt = () => {
      document.removeEventListener("keydown", onKey)
      overlay.classList.add("smart-cart--closing")
      setTimeout(() => {
        overlay.remove()
        document.body.classList.remove("smart-cart-open")
      }, 180)
    }
    document.addEventListener("keydown", onKey)

    renderTable()
  },

  _renderTable(items, chains, state) {
    // Columns: delete | product | qty | row-switch | chains[…]
    const head = `
      <thead>
        <tr>
          <th class="smart-cart-th smart-cart-th--remove"></th>
          <th class="smart-cart-th smart-cart-th--product"></th>
          <th class="smart-cart-th smart-cart-th--qty"></th>
          <th class="smart-cart-th smart-cart-th--switch"></th>
          ${chains.map((c) => `
            <th class="smart-cart-th smart-cart-th--chain">
              <div class="smart-cart-th__chain">
                <img src="${CHAIN_ICONS[c]}" alt=""/>
                <span>${escHtml(CHAIN_NAMES[c])}</span>
              </div>
            </th>
          `).join("")}
        </tr>
      </thead>
    `
    const leadingCols = 4

    // Per-row: per-product winner is the cheapest selected-chain
    // price among the row's prices. The winning cell gets a circle.
    const rows = items.map((it) => {
      const p = it.product
      const isDisabled = state.disabled.has(String(p.id)) || state.disabled.has(p.id)
      const winner = isDisabled ? null : bestChainFor(p, state.selected)

      const qty = p.qty || 1
      const cells = chains.map((c) => {
        const r = (p.prices || []).find((x) => x.chain === c)
        if (!r || !Number.isFinite(r.price)) {
          return `<td class="smart-cart-td smart-cart-td--empty"><span class="smart-cart-td__amt smart-cart-td__amt--empty">—</span></td>`
        }
        const isOff = !state.selected.has(c)
        const isWinner = winner && winner.chain === c && winner.price === r.price
        return `
          <td class="smart-cart-td${isOff ? " smart-cart-td--off" : ""}${isWinner ? " smart-cart-td--win" : ""}">
            <span class="smart-cart-td__amt">${formatClp(r.price * qty)}</span>
          </td>
        `
      }).join("")

      // Group header band before the first product of a group.
      const bandRow = it.isFirstInGroup
        ? `
          <tr class="smart-cart-group-hd">
            <th colspan="${chains.length + leadingCols}">
              <span class="smart-cart-group-hd__label">${escHtml(it.groupLabel)}</span>
            </th>
          </tr>
        `
        : ""

      return bandRow + `
        <tr class="smart-cart-row${isDisabled ? " smart-cart-row--disabled" : ""}${!isDisabled && !winner ? " smart-cart-row--missing" : ""}${it.isGroup ? " smart-cart-row--in-group" : ""}${it.isLastInGroup ? " smart-cart-row--in-group-end" : ""}">
          <td class="smart-cart-td smart-cart-td--remove">
            <button type="button" class="smart-cart-remove" aria-label="Quitar"
                    data-smart-remove="${it.slotIdx}" data-smart-remove-product="${it.pIdx}">×</button>
          </td>
          <th class="smart-cart-th smart-cart-th--product">
            <button type="button" class="smart-cart-product"
                    data-product-detail
                    data-slot-idx="${it.slotIdx}" data-product-idx="${it.pIdx}">
              <div class="smart-cart-product__img">
                ${p.image_url ? `<img src="${escHtml(p.image_url)}" alt=""/>` : ""}
              </div>
              <div class="smart-cart-product__meta">
                <div class="smart-cart-product__name">${escHtml(p.name)}</div>
                <div class="smart-cart-product__sub">
                  ${p.brand ? `<span class="smart-cart-product__brand">${escHtml(p.brand)}</span>` : ""}
                  ${p.brand ? `<span class="smart-cart-product__sep">·</span>` : ""}
                  ${renderPrice(p.prices)}
                </div>
              </div>
            </button>
          </th>
          <td class="smart-cart-td smart-cart-td--qty">
            <div class="smart-cart-qty">
              <button type="button" data-smart-qty="dec"
                      data-smart-qty-slot="${it.slotIdx}" data-smart-qty-product="${it.pIdx}"
                      aria-label="Quitar uno">−</button>
              <span>${p.qty || 1}</span>
              <button type="button" data-smart-qty="inc"
                      data-smart-qty-slot="${it.slotIdx}" data-smart-qty-product="${it.pIdx}"
                      aria-label="Agregar uno">+</button>
            </div>
          </td>
          <td class="smart-cart-td smart-cart-td--row-switch">
            <label class="smart-cart-row-switch">
              <input type="checkbox" data-product-toggle="${escHtml(p.id)}" ${isDisabled ? "" : "checked"}/>
              <span class="smart-cart-row-switch__track"></span>
            </label>
          </td>
          ${cells}
        </tr>
      `
    }).join("")

    // Footer: per-chain subtotals + chain switch row + grand total.
    // For active chains we sum the products that landed on it
    // (i.e., where it's the row winner). For inactive chains we
    // show the column sum — what the user would pay if that chain
    // were the only one selected — so they can preview the cost
    // of toggling it on alone.
    let total = 0
    const perChain = Object.fromEntries(chains.map((c) => [c, 0]))
    for (const it of items) {
      const p = it.product
      if (state.disabled.has(p.id) || state.disabled.has(String(p.id))) continue
      const w = bestChainFor(p, state.selected)
      if (w) {
        const cost = w.price * (p.qty || 1)
        total += cost
        perChain[w.chain] = (perChain[w.chain] || 0) + cost
      }
    }
    // Column-sum fallback for unselected chains.
    const columnSum = Object.fromEntries(chains.map((c) => [c, 0]))
    for (const it of items) {
      const p = it.product
      if (state.disabled.has(p.id) || state.disabled.has(String(p.id))) continue
      for (const c of chains) {
        const r = (p.prices || []).find((x) => x.chain === c)
        if (r && Number.isFinite(r.price)) {
          columnSum[c] += r.price * (p.qty || 1)
        }
      }
    }

    const chainSwitchRow = `
      <tr class="smart-cart-foot smart-cart-foot--switches">
        <th class="smart-cart-th" colspan="${leadingCols}">Supermercados</th>
        ${chains.map((c) => `
          ${(() => {
            const isOn = state.selected.has(c)
            const amt = isOn ? perChain[c] : columnSum[c]
            return `
              <td class="smart-cart-td smart-cart-td--switch">
                <label class="smart-cart-chain-switch">
                  <input type="checkbox" data-chain="${c}" ${isOn ? "checked" : ""}/>
                  <span class="smart-cart-chain-switch__track"></span>
                  <span class="smart-cart-chain-cell__amt${amt > 0 ? "" : " smart-cart-chain-cell__amt--zero"}${isOn ? "" : " smart-cart-chain-cell__amt--off"}">
                    ${amt > 0 ? formatClp(amt) : ""}
                  </span>
                </label>
              </td>
            `
          })()}
        `).join("")}
      </tr>
    `

    const totalRow = `
      <tr class="smart-cart-foot smart-cart-foot--total">
        <th class="smart-cart-th" colspan="${leadingCols}">Total</th>
        <td class="smart-cart-td smart-cart-td--total" colspan="${chains.length}">${formatClp(total)}</td>
      </tr>
    `

    return `
      <table class="smart-cart-table">
        ${head}
        <tbody>${rows}</tbody>
        <tfoot>${chainSwitchRow}${totalRow}</tfoot>
      </table>
    `
  },
}

// ── Product detail sub-popover ────────────────────────────────────

const ProductDetail = {
  open(product, cart) {
    if (document.querySelector(".product-detail")) return
    const overlay = document.createElement("div")
    overlay.className = "product-detail"
    overlay.innerHTML = `
      <div class="product-detail__backdrop" data-pd-close></div>
      <div class="product-detail__panel" role="dialog" aria-modal="true">
        <button class="product-detail__close" type="button" aria-label="Cerrar" data-pd-close>×</button>
        <div class="product-detail__img">
          <div class="product-detail__img-frame" data-pd-image></div>
          <div class="product-detail__img-switch" data-pd-switch></div>
        </div>
        <div class="product-detail__main">
          <h3 class="product-detail__name">${escHtml(product.name)}</h3>
          ${product.brand ? `<div class="product-detail__brand">${escHtml(product.brand)}</div>` : ""}
          <div class="product-detail__stores" data-pd-stores></div>
        </div>
      </div>
    `
    document.body.appendChild(overlay)

    let listings = null
    let activeChain = null

    const renderHero = () => {
      const frame = overlay.querySelector("[data-pd-image]")
      const switcher = overlay.querySelector("[data-pd-switch]")

      // Build the list of available images. Prefer listing-level
      // images (each chain's own product photo) over the static
      // product image_url.
      let images = []
      if (listings) {
        const seen = new Set()
        for (const l of listings) {
          if (l.image_url && !seen.has(l.image_url)) {
            seen.add(l.image_url)
            images.push({chain: l.chain, url: l.image_url})
          }
        }
      }
      if (images.length === 0 && product.image_url) {
        images = [{chain: null, url: product.image_url}]
      }
      if (images.length === 0) {
        frame.innerHTML = `<div class="product-detail__img-empty">Sin imagen</div>`
        switcher.innerHTML = ""
        return
      }

      const active = images.find((i) => i.chain === activeChain) || images[0]
      activeChain = active.chain
      frame.innerHTML = `<img src="${escHtml(active.url)}" alt=""/>`

      switcher.innerHTML = images.length > 1
        ? images.map((img) => `
            <button type="button"
                    class="pd-img-switch${img.chain === active.chain ? " is-active" : ""}"
                    data-pd-switch-chain="${img.chain ?? ""}"
                    aria-label="${escHtml(CHAIN_NAMES[img.chain] || "")}">
              ${img.chain
                ? `<img src="${CHAIN_ICONS[img.chain] || ""}" alt=""/>`
                : `<span class="pd-img-switch__dot"></span>`}
            </button>
          `).join("")
        : ""
    }

    const renderStores = () => {
      const body = overlay.querySelector("[data-pd-stores]")
      body.innerHTML = ProductDetail._renderStores(product, listings)
    }

    if (cart && cart.pushEvent) {
      cart.pushEvent("product_detail", {id: product.id}, (reply) => {
        listings = (reply && reply.listings) || []
        renderHero()
        renderStores()
      })
    }

    renderHero()
    renderStores()

    const onClick = (e) => {
      if (e.target.closest("[data-pd-close]")) { closeIt(); return }
      const switchBtn = e.target.closest("[data-pd-switch-chain]")
      if (switchBtn) {
        const chain = switchBtn.dataset.pdSwitchChain
        activeChain = chain === "" ? null : chain
        renderHero()
        return
      }
    }
    overlay.addEventListener("click", onClick)
    const onKey = (e) => { if (e.key === "Escape") closeIt() }
    document.addEventListener("keydown", onKey)
    const closeIt = () => {
      overlay.removeEventListener("click", onClick)
      document.removeEventListener("keydown", onKey)
      overlay.classList.add("product-detail--closing")
      setTimeout(() => overlay.remove(), 160)
    }
  },

  // Stores table — one row per chain. Both the chain name and the
  // price are anchored to the chain's pdp_url so either is a
  // clickable shortcut into that store. Live `listings` (with raw)
  // wins over the static prices snapshot once it arrives.
  _renderStores(product, listings) {
    if (listings === null) {
      // Initial render before the LiveView reply lands.
      const rows = (product.prices || [])
        .filter((r) => Number.isFinite(r.price))
        .sort((a, b) => a.price - b.price)
      return rows.length === 0
        ? `<div class="pd-empty">Sin tiendas disponibles.</div>`
        : ProductDetail._storesTable(rows.map((r) => ({
            chain: r.chain,
            regular_price: r.price,
            promo_price: null,
            pdp_url: r.url,
            name: null,
          })))
    }
    if (listings.length === 0) return `<div class="pd-empty">Sin tiendas disponibles.</div>`
    const sorted = [...listings].sort((a, b) => {
      const ap = Number.isFinite(a.regular_price) ? a.regular_price : Infinity
      const bp = Number.isFinite(b.regular_price) ? b.regular_price : Infinity
      return ap - bp
    })
    return ProductDetail._storesTable(sorted)
  },

  _storesTable(rows) {
    return `
      <ul class="pd-stores">
        ${rows.map((l) => {
          const reg = l.regular_price
          const promo = (Number.isFinite(l.promo_price) && Number.isFinite(reg) && l.promo_price < reg) ? l.promo_price : null
          const eff = promo != null ? promo : reg
          const priceInner = promo != null
            ? `<span class="pd-stores__price-eff">${formatClp(eff)}</span><span class="pd-stores__price-was">${formatClp(reg)}</span>`
            : (Number.isFinite(eff) ? formatClp(eff) : "—")
          const inner = `
            <div class="pd-stores__hd">
              <img class="pd-stores__chain-icon" src="${CHAIN_ICONS[l.chain] || ""}" alt=""/>
              <span class="pd-stores__chain-name">${escHtml(CHAIN_NAMES[l.chain] || l.chain)}</span>
              <span class="pd-stores__price">${priceInner}</span>
            </div>
            ${l.name ? `<div class="pd-stores__sub">${escHtml(l.name)}</div>` : ""}
          `
          return `
            <li class="pd-stores__row">
              ${l.pdp_url
                ? `<a class="pd-stores__card" href="${escHtml(l.pdp_url)}" target="_blank" rel="noopener noreferrer">${inner}</a>`
                : `<div class="pd-stores__card pd-stores__card--off">${inner}</div>`}
            </li>
          `
        }).join("")}
      </ul>
    `
  },
}
