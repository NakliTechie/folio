import { Turbo } from "@hotwired/turbo-rails"

// Turbo's built-in progress bar positions itself with inline styles, which a strict
// style-src policy correctly blocks. Delay that implementation and provide the same loading
// feedback through a class-only indicator that needs no CSP exception.
Turbo.config.drive.progressBarDelay = 60_000

const showNavigationProgress = () => {
  document.body?.classList.add("turbo-loading")
  document.body?.setAttribute("aria-busy", "true")
}

const hideNavigationProgress = () => {
  document.body?.classList.remove("turbo-loading")
  document.body?.removeAttribute("aria-busy")
}

const moveFocusToMainContent = (event) => {
  const target = document.querySelector("#main-content")
  if (!target) return

  event.preventDefault()
  target.setAttribute("tabindex", "-1")
  target.focus({ preventScroll: true })
  target.scrollIntoView({ block: "start" })
  window.history.replaceState(null, "", "#main-content")
}

document.addEventListener("turbo:before-fetch-request", showNavigationProgress)
document.addEventListener("turbo:before-cache", hideNavigationProgress)
document.addEventListener("turbo:fetch-request-error", hideNavigationProgress)

document.addEventListener("turbo:load", () => {
  hideNavigationProgress()
  document.querySelector("[data-skip-link]")?.addEventListener("click", moveFocusToMainContent, { once: true })
  document.querySelectorAll("[data-print-page]").forEach((button) => {
    button.addEventListener("click", () => window.print(), { once: true })
  })
})
