(() => {
  const branchPattern = /^release\/v(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)$/;

  function hydrateReleaseLabs() {
    document.querySelectorAll("[data-release-branch]").forEach((lab) => {
      if (lab.dataset.ready === "true") return;
      lab.dataset.ready = "true";

      const input = lab.querySelector("[data-release-input]");
      const error = lab.querySelector("[data-release-error]");
      const fields = {
        version: lab.querySelector("[data-release-version]"),
        tag: lab.querySelector("[data-release-tag]"),
        kind: lab.querySelector("[data-release-kind]"),
        asset: lab.querySelector("[data-release-asset]"),
        state: lab.querySelector("[data-release-state]"),
      };

      const render = () => {
        const match = input.value.trim().match(branchPattern);
        if (!match) {
          error.hidden = false;
          error.textContent = "Use release/v<major>.<minor>.<patch>[-prerelease].";
          input.setAttribute("aria-invalid", "true");
          return;
        }

        const version = match[1];
        const prerelease = version.includes("-");
        error.hidden = true;
        input.removeAttribute("aria-invalid");
        fields.version.textContent = version;
        fields.tag.textContent = `v${version}`;
        fields.kind.textContent = prerelease ? "Pre-release" : "Stable release";
        fields.asset.textContent = `Capsule-v${version}.dmg`;
        fields.state.textContent = prerelease ? "Pre-release" : "Stable release";
      };

      input.addEventListener("input", render);
      render();
    });
  }

  if (typeof document$ !== "undefined") {
    document$.subscribe(hydrateReleaseLabs);
  } else if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", hydrateReleaseLabs, { once: true });
  } else {
    hydrateReleaseLabs();
  }
})();
