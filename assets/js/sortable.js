// Pointer-driven row reorder for tables wrapped in `[data-sortable]`.
// Drag handle is `[data-sort-handle]` carrying `data-sort-id`. On
// pointerup, the new order is POSTed to the wrapper's
// `data-sortable-url` as `ids[]=…` (with the page CSRF token).
//
// Ported verbatim from macatlas/priv/static/assets/js/admin.js so the
// behavior matches its sibling app.

function createSortGhost(tr, rect) {
  const sourceTable = tr.closest("table");
  const wrapper = document.createElement("div");
  wrapper.className = "sort-ghost";
  wrapper.style.position = "fixed";
  wrapper.style.left = rect.left + "px";
  wrapper.style.top = rect.top + "px";
  wrapper.style.width = rect.width + "px";

  const ghostTable = document.createElement("table");
  if (sourceTable) ghostTable.className = sourceTable.className;
  const tbody = document.createElement("tbody");
  const clone = tr.cloneNode(true);

  Array.from(tr.children).forEach(function (cell, i) {
    const cloneCell = clone.children[i];
    if (cloneCell) cloneCell.style.width = cell.getBoundingClientRect().width + "px";
  });

  tbody.appendChild(clone);
  ghostTable.appendChild(tbody);
  wrapper.appendChild(ghostTable);
  return wrapper;
}

export function initSortable() {
  let dragRow = null;
  let dragHandle = null;
  let container = null;
  let ghost = null;
  let offsetY = 0;

  document.addEventListener("pointerdown", function (e) {
    const handle = e.target.closest("[data-sort-handle]");
    if (!handle) return;
    const tr = handle.closest("tr");
    const c = handle.closest("[data-sortable]");
    if (!tr || !c) return;

    e.preventDefault();
    dragRow = tr;
    dragHandle = handle;
    container = c;

    const rect = tr.getBoundingClientRect();
    offsetY = e.clientY - rect.top;

    ghost = createSortGhost(tr, rect);
    document.body.appendChild(ghost);

    tr.classList.add("is-sort-dragging");
    handle.setPointerCapture(e.pointerId);
  });

  document.addEventListener("pointermove", function (e) {
    if (!dragRow) return;

    if (ghost) {
      ghost.style.top = (e.clientY - offsetY) + "px";
    }

    const tbody = dragRow.parentNode;
    if (!tbody) return;

    const rows = Array.from(tbody.querySelectorAll("tr")).filter(function (row) {
      return row !== dragRow && row.querySelector("[data-sort-handle]");
    });

    let inserted = false;
    for (const row of rows) {
      const rect = row.getBoundingClientRect();
      if (e.clientY < rect.bottom) {
        if (row.previousSibling !== dragRow) tbody.insertBefore(dragRow, row);
        inserted = true;
        break;
      }
    }

    if (!inserted) {
      const last = rows[rows.length - 1];
      if (last && last.nextSibling !== dragRow) {
        tbody.insertBefore(dragRow, last.nextSibling);
      }
    }
  });

  document.addEventListener("pointerup", function () {
    if (!dragRow) return;
    const c = container;
    const handle = dragHandle;

    dragRow.classList.remove("is-sort-dragging");
    if (ghost && ghost.parentNode) ghost.parentNode.removeChild(ghost);
    ghost = null;
    dragRow = null;
    dragHandle = null;
    container = null;

    if (!c || !c.dataset.sortableUrl) return;

    const ids = Array.from(c.querySelectorAll("[data-sort-handle]")).map(
      function (h) { return h.dataset.sortId; }
    );

    const csrf =
      (document.querySelector('meta[name="csrf-token"]') || {}).content || "";
    const fd = new FormData();
    fd.append("_csrf_token", csrf);
    ids.forEach(function (id) { fd.append("ids[]", id); });

    fetch(c.dataset.sortableUrl, {
      method: "POST",
      body: fd,
      credentials: "same-origin",
    });

    if (handle) {
      try { handle.releasePointerCapture && handle.releasePointerCapture(); }
      catch (_) {}
    }
  });
}
