import "@hotwired/turbo-rails"

document.addEventListener("turbo:load", () => {
  document.querySelectorAll("[data-print-page]").forEach((button) => {
    button.addEventListener("click", () => window.print(), { once: true })
  })
})
