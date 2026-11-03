import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"

class Element {
  constructor(text, start, end) {
    this.textContent = text
    this.dataset = { start, end }
  }
  remove() { this.removed = true }
}
let observer
let connected = true
const source = { hasAttribute: () => connected }
const context = {
  Controller: class {}, HTMLElement: Element,
  document: { querySelector: () => source },
  MutationObserver: class {
    constructor(callback) { this.callback = callback; observer = this }
    observe() {}
    disconnect() { this.disconnected = true }
  }
}
const code = fs.readFileSync("app/javascript/controllers/run_log_controller.js", "utf8")
  .replace(/^import .*\n/, "")
  .replace("export default class", "globalThis.LogController = class")
vm.runInNewContext(code, context)
const controller = new context.LogController()
controller.lengthValue = 2
const overlap = new Element("a😀bc", 0, 4)
controller.chunksAdded([{ addedNodes: [overlap] }])
assert.equal(overlap.textContent, "bc")
assert.equal(controller.lengthValue, 4)
const duplicate = new Element("bc", 2, 4)
controller.chunksAdded([{ addedNodes: [duplicate] }])
assert.equal(duplicate.removed, true)
let syncs = 0
controller.resync = () => syncs++
controller.watchStreamSource()
assert.equal(syncs, 1)
connected = false
observer.callback()
connected = true
observer.callback()
assert.equal(syncs, 2)
assert.ok(!observer.disconnected)
const gap = new Element("gap", 8, 11)
controller.chunksAdded([{ addedNodes: [gap] }])
assert.equal(syncs, 3)
// A response can include only the first half of a newly received chunk.
delete controller.resync
controller.urlValue = "/test.json"
context.fetch = async () => ({ ok: true, json: async () => ({ log: "a😀", length: 2, status_html: "done" }) })
const trailing = new Element("a😀bc", 0, 4)
controller.logTarget = {
  textContent: "", querySelectorAll: () => [trailing],
  append(span) { this.textContent += span.textContent }
}
controller.element = { querySelector: () => null }
await controller.resync()
assert.equal(controller.logTarget.textContent, "a😀bc")
assert.equal(controller.lengthValue, 4)
console.log("live log overlap, duplicates, gaps, reconnection, and resync passed")
