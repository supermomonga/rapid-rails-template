import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.observer = new ResizeObserver(() => this.revealCurrent())
    this.observer.observe(this.element)
    this.revealCurrent()
  }

  disconnect() {
    this.observer.disconnect()
  }

  revealCurrent() {
    this.element.querySelectorAll('[role="tablist"]').forEach(list => {
      const active = list.querySelector(':scope > [aria-selected="true"]')
      if (!active) return
      const scroller = list.parentElement
      const box = active.getBoundingClientRect()
      const frame = scroller.getBoundingClientRect()
      if (box.left < frame.left || box.right > frame.right) {
        scroller.scrollLeft += box.left - frame.left - (frame.width - box.width) / 2
      }
    })
    this.element.querySelectorAll('[data-with-menu-scroll]').forEach(scroller => {
      const active = scroller.querySelector('[aria-current="page"]')
      if (!active || scroller.scrollWidth <= scroller.clientWidth) return
      const box = active.getBoundingClientRect()
      const frame = scroller.getBoundingClientRect()
      scroller.scrollLeft += box.left - frame.left - (frame.width - box.width) / 2
    })
  }
}
