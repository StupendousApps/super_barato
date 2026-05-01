// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/super_barato"
import topbar from "../vendor/topbar"
import {initSortable} from "./sortable"

// Rails hook — purely frontend collapse/expand for the public home
// page's left (categories) and right (cart) sidebars. The initial
// state is applied by an inline script in the layout root before
// CSS computes (see home_root.html.heex), so the rails render in
// their saved state on first paint. This hook just listens for
// clicks on `[data-rail-toggle]` buttons and flips the same
// `data-rail-left` / `data-rail-right` attributes on <html> +
// localStorage. The LiveView server is never told.
const Rails = {
  KEY: "super_barato.rails.collapsed",
  mounted() {
    this.clickHandler = (event) => {
      const button = event.target.closest("[data-rail-toggle]")
      if (!button || !this.el.contains(button)) return
      const which = button.dataset.railToggle
      if (which !== "left" && which !== "right") return
      const current = this.read()
      current[which] = !current[which]
      this.write(current)
      this.apply(current)
    }
    this.el.addEventListener("click", this.clickHandler)
  },
  destroyed() {
    if (this.clickHandler) this.el.removeEventListener("click", this.clickHandler)
  },
  apply({left, right}) {
    const d = document.documentElement
    d.dataset.railLeft  = left  ? "collapsed" : "expanded"
    d.dataset.railRight = right ? "collapsed" : "expanded"
  },
  read() {
    try {
      const raw = window.localStorage.getItem(this.KEY)
      const parsed = raw ? JSON.parse(raw) : {}
      return {left: !!parsed.left, right: !!parsed.right}
    } catch (_e) {
      return {left: false, right: false}
    }
  },
  write({left, right}) {
    try {
      window.localStorage.setItem(this.KEY, JSON.stringify({left: !!left, right: !!right}))
    } catch (_e) {}
  },
}

// Picker hook — open/close state lives entirely client side on a
// `data-open` attribute. The LiveView re-renders the trigger label
// (and the panel contents) on every URL patch; the hook re-applies
// `data-open` after each morph so the panel doesn't snap shut.
const Picker = {
  mounted() {
    this._open = false
    this.toggle = this.el.querySelector("[data-picker-toggle]")
    this._onElClick = (e) => {
      // Click on the toggle: flip open/close and don't bubble to the
      // document handler (which would immediately re-close us).
      if (e.target.closest("[data-picker-toggle]")) {
        e.stopPropagation()
        this._open = !this._open
        this.apply()
        return
      }
      // Click on a link inside the panel: force close synchronously
      // so the panel collapses regardless of how the click bubbles
      // through Phoenix's patch handling.
      if (e.target.closest("a")) {
        this._open = false
        this.apply()
      }
    }
    this.el.addEventListener("click", this._onElClick)
  },
  beforeUpdate() {
    this._open = this.el.hasAttribute("data-open")
  },
  updated() { this.apply() },
  destroyed() {
    if (this._onElClick) this.el.removeEventListener("click", this._onElClick)
  },
  apply() {
    if (this._open) this.el.setAttribute("data-open", "")
    else this.el.removeAttribute("data-open")
  },
}

// SeenCounter hook — tracks which `.card[data-product-index]`
// elements are currently intersecting the viewport and renders the
// highest visible index ("you're at item N out of M"). Re-runs
// `observe()` on every LV update so infinite-scroll appends start
// being tracked. The server pushes `seen_counter:reset` on filter
// changes so the visible Set drops back to zero for the new set.
const SeenCounter = {
  mounted() {
    this.visible = new Set()
    this.observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const idx = parseInt(entry.target.dataset.productIndex, 10)
        if (Number.isNaN(idx)) continue
        if (entry.isIntersecting) this.visible.add(idx)
        else this.visible.delete(idx)
      }
      this.render()
    })
    this.observe()
    this.handleEvent("seen_counter:reset", () => {
      this.visible.clear()
      this.render()
    })
  },
  updated() { this.observe() },
  destroyed() { if (this.observer) this.observer.disconnect() },
  observe() {
    document.querySelectorAll(".card[data-product-index]").forEach((c) => this.observer.observe(c))
    this.render()
  },
  render() {
    const seenEl = this.el.querySelector("[data-seen]")
    if (!seenEl) return
    const max = this.visible.size === 0 ? 0 : Math.max(...this.visible)
    seenEl.textContent = max
  },
}

// InfiniteScroll hook — fires `load_more` whenever a sentinel
// element scrolls into view. The LiveView re-renders the sentinel
// in place after each append, so the same element keeps observing
// the next batch's tail. When all results are loaded the sentinel
// is removed by the server and the observer disconnects on
// `destroyed`.
const InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        this.pushEvent("load_more")
      }
    }, {rootMargin: "400px 0px"})
    this.observer.observe(this.el)
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Rails, Picker, InfiniteScroll, SeenCounter},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Outside click closes every open picker. (In-panel link clicks are
// handled inside the Picker hook itself.)
document.addEventListener("click", (event) => {
  document.querySelectorAll(".picker[data-open]").forEach((p) => {
    if (!p.contains(event.target)) p.removeAttribute("data-open")
  })
})

// connect if there are any LiveViews on the page
liveSocket.connect()

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initSortable, {once: true})
} else {
  initSortable()
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

