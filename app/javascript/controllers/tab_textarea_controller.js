import { Controller } from "@hotwired/stimulus"

// Lets the Tab key insert a tab in the code editor instead of moving focus.
export default class extends Controller {
  connect() {
    this.element.addEventListener("keydown", this.insertTab)
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.insertTab)
  }

  insertTab = (event) => {
    if (event.key !== "Tab" || event.shiftKey) return
    event.preventDefault()
    const { selectionStart, selectionEnd, value } = this.element
    this.element.value = value.slice(0, selectionStart) + "\t" + value.slice(selectionEnd)
    this.element.selectionStart = this.element.selectionEnd = selectionStart + 1
  }
}
