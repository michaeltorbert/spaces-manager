const tabs = Array.from(document.querySelectorAll(".tab-button"));
const directions = Array.from(document.querySelectorAll(".direction"));

function activateDirection(id) {
  directions.forEach((direction) => {
    const isActive = direction.id === id;
    direction.classList.toggle("is-active", isActive);
    direction.hidden = !isActive;
  });

  tabs.forEach((tab) => {
    const isActive = tab.dataset.direction === id;
    tab.classList.toggle("is-active", isActive);
    tab.setAttribute("aria-selected", String(isActive));
  });
}

tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    activateDirection(tab.dataset.direction);
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
});
