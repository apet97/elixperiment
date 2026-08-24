const CopyToClipboard = {
  mounted() {
    this.button = this.el.querySelector("button")
    this.buttonLabel = this.el.querySelector("[data-copy-button-label]")
    this.status = this.el.querySelector("[role='status']")
    this.copyLabel = this.el.dataset.copyLabel
    this.feedbackGeneration = 0
    this.onCopy = () => this.copy()
    this.button.addEventListener("click", this.onCopy)
  },

  destroyed() {
    this.feedbackGeneration += 1
    this.button.removeEventListener("click", this.onCopy)
    window.clearTimeout(this.resetTimer)
    window.cancelAnimationFrame(this.feedbackFrame)
  },

  async copy() {
    const generation = ++this.feedbackGeneration
    const source = document.getElementById(this.el.dataset.copySource)
    this.clearFeedback()

    if (!source) {
      this.setFeedback(generation, "Copy failed", `Could not find ${this.copyLabel}.`)
      return
    }

    try {
      await this.write(source)

      this.setFeedback(generation, "Copied", `${this.copyLabel} copied.`)
    } catch (_error) {
      this.setFeedback(
        generation,
        "Copy failed",
        `Could not copy ${this.copyLabel}. Select and copy it manually.`
      )
    } finally {
      if (generation === this.feedbackGeneration) this.button.focus()
    }
  },

  async write(source) {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(source.value)
      return
    }

    source.focus()
    source.select()
    source.setSelectionRange(0, source.value.length)

    if (!document.execCommand("copy")) throw new Error("copy command failed")

    source.setSelectionRange(0, 0)
  },

  clearFeedback() {
    window.clearTimeout(this.resetTimer)
    window.cancelAnimationFrame(this.feedbackFrame)
    this.buttonLabel.textContent = "Copy"
    this.button.setAttribute("aria-label", `Copy ${this.copyLabel}`)
    this.status.textContent = ""
  },

  setFeedback(generation, buttonText, statusText) {
    if (generation !== this.feedbackGeneration) return

    this.clearFeedback()
    this.buttonLabel.textContent = buttonText
    this.button.setAttribute("aria-label", `${buttonText} ${this.copyLabel}`)

    this.feedbackFrame = window.requestAnimationFrame(() => {
      if (generation !== this.feedbackGeneration) return

      this.status.textContent = statusText

      this.resetTimer = window.setTimeout(() => {
        if (generation !== this.feedbackGeneration) return

        this.buttonLabel.textContent = "Copy"
        this.button.setAttribute("aria-label", `Copy ${this.copyLabel}`)
        this.status.textContent = ""
      }, 1800)
    })
  },
}

export default CopyToClipboard
