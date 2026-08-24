const OutlineReorder = {
  mounted() {
    this.sourceId = null
    this.branchPath = null

    this.onDragStart = (event) => {
      if (this.el.dataset.canManage !== "true") return
      const card = event.target.closest("[data-node-id]")
      if (!card || !this.el.contains(card)) return
      if (event.target.closest("input, textarea, select, button, label, form, a, [data-no-drag]")) {
        event.preventDefault()
        return
      }
      this.sourceId = card.dataset.nodeId
      this.branchPath = card.dataset.branchPath
      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", this.sourceId)
      card.setAttribute("aria-grabbed", "true")
    }

    this.onDragOver = (event) => {
      const card = event.target.closest("[data-node-id]")
      if (!card || !this.el.contains(card)) return
      if (card.dataset.branchPath !== this.branchPath) return
      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
    }

    this.onDrop = (event) => {
      const card = event.target.closest("[data-node-id]")
      if (!card || !this.el.contains(card)) return
      event.preventDefault()
      const sourceId = this.sourceId || event.dataTransfer.getData("text/plain")
      const targetId = card.dataset.nodeId
      const branchPath = this.branchPath || card.dataset.branchPath
      this.clearDrag()
      if (!sourceId || !targetId || sourceId === targetId) return
      this.pushEvent("reorder", {
        source_id: sourceId,
        target_id: targetId,
        branch_path: branchPath,
      })
    }

    this.onDragEnd = () => this.clearDrag()

    this.el.addEventListener("dragstart", this.onDragStart)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("drop", this.onDrop)
    this.el.addEventListener("dragend", this.onDragEnd)
  },

  clearDrag() {
    this.el.querySelectorAll('[aria-grabbed="true"]').forEach((el) => {
      el.setAttribute("aria-grabbed", "false")
    })
    this.sourceId = null
    this.branchPath = null
  },

  destroyed() {
    this.clearDrag()
    this.el.removeEventListener("dragstart", this.onDragStart)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("dragend", this.onDragEnd)
  },

  disconnected() {
    this.clearDrag()
  },

  reconnected() {
    this.clearDrag()
  },
}

export default OutlineReorder
