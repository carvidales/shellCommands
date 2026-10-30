import { Controller } from "@hotwired/stimulus"

// Keeps the console pinned to the newest output, unless the user has
// scrolled up to read something.
export default class extends Controller {
  connect() {
    this.pinned = true
    this.element.scrollTop = this.element.scrollHeight
    this.element.addEventListener("scroll", this.trackPinned)
    this.observer = new MutationObserver(() => {
      if (this.pinned) this.element.scrollTop = this.element.scrollHeight
    })
    this.observer.observe(this.element, { childList: true, characterData: true, subtree: true })
  }

  disconnect() {
    this.observer.disconnect()
    this.element.removeEventListener("scroll", this.trackPinned)
  }

  trackPinned = () => {
    const { scrollTop, scrollHeight, clientHeight } = this.element
    this.pinned = scrollHeight - scrollTop - clientHeight < 40
  }
}
