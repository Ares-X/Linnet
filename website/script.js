// Clipboard feedback is shared by the product page and the guide.
for (const button of document.querySelectorAll('[data-copy]')) {
  button.addEventListener('click', async () => {
    const status = button.closest('.command-row').nextElementSibling;
    try {
      await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
      status.textContent = '命令已复制。';
    } catch {
      status.textContent = '无法复制，请选中上方命令后手动复制。';
    }
  });
}

// All theme images remain readable when JavaScript is unavailable.
const gallery = document.querySelector('[data-theme-gallery]');
if (gallery) {
  const controls = document.querySelector('.theme-controls');
  const panels = [...gallery.querySelectorAll('.theme-card')];
  const tabs = panels.map((panel, index) => {
    const tab = document.createElement('button');
    panel.id = `theme-panel-${index}`;
    panel.setAttribute('role', 'tabpanel');
    panel.tabIndex = 0;
    panel.setAttribute('aria-labelledby', `theme-tab-${index}`);
    tab.id = `theme-tab-${index}`;
    tab.type = 'button';
    tab.textContent = panel.querySelector('h3').textContent;
    tab.setAttribute('role', 'tab');
    tab.setAttribute('aria-controls', panel.id);
    controls.append(tab);
    return tab;
  });
  const selectTheme = (index, focus = false) => {
    tabs.forEach((tab, i) => {
      tab.setAttribute('aria-selected', String(i === index));
      tab.tabIndex = i === index ? 0 : -1;
      panels[i].hidden = i !== index;
    });
    if (focus) {
      tabs[index].focus({ preventScroll: true });
      tabs[index].scrollIntoView({ block: 'nearest', inline: 'nearest' });
    }
  };
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectTheme(index));
    tab.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next === undefined) return;
      event.preventDefault();
      selectTheme(next, true);
    });
  });
  selectTheme(0);
  controls.hidden = false;
  gallery.classList.add('is-interactive');
}

const guideNavigation = document.querySelector('.guide-navigation');
if (guideNavigation) {
  const desktop = matchMedia('(min-width: 1000px)');
  const links = [...guideNavigation.querySelectorAll('a[href^="#"]')];
  const sections = links.map(link => document.querySelector(link.getAttribute('href')));
  const currentLabel = guideNavigation.querySelector('.nav-current-label');
  const fitNavigation = () => {
    guideNavigation.open = desktop.matches;
    guideNavigation.querySelector('summary').tabIndex = desktop.matches ? -1 : 0;
  };
  fitNavigation();
  desktop.addEventListener('change', fitNavigation);
  guideNavigation.querySelector('summary').addEventListener('click', event => {
    if (desktop.matches) event.preventDefault();
  });
  guideNavigation.addEventListener('click', event => {
    if (!event.target.closest('a') || desktop.matches) return;
    guideNavigation.open = false;
  });
  const revealHash = () => {
    let target;
    try { target = document.getElementById(decodeURIComponent(location.hash.slice(1))); }
    catch { return; }
    if (!target) return;
    for (let node = target; node; node = node.parentElement) {
      if (node instanceof HTMLDetailsElement) node.open = true;
    }
  };
  revealHash();
  window.addEventListener('hashchange', revealHash);
  let scheduled = false;
  const markSection = () => {
    scheduled = false;
    const boundary = desktop.matches ? 145 : 190;
    let current = 0;
    sections.forEach((section, index) => {
      if (section.getBoundingClientRect().top <= boundary) current = index;
    });
    links.forEach((link, index) => {
      if (index === current) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    });
    currentLabel.textContent = links[current].textContent.replace(/^\d+/, '').trim();
  };
  const scheduleSection = () => {
    if (!scheduled) { scheduled = true; requestAnimationFrame(markSection); }
  };
  window.addEventListener('scroll', scheduleSection, { passive: true });
  window.addEventListener('resize', scheduleSection);
  markSection();
}

const recording = document.querySelector('[data-recording]');
if (recording) {
  const image = recording.querySelector('img');
  const source = recording.querySelector('source');
  const toggle = recording.querySelector('.gif-toggle');
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  let playing;
  const setAnimation = enabled => {
    playing = enabled;
    const path = enabled ? image.dataset.animation : image.dataset.still;
    source.srcset = path;
    image.src = path;
    toggle.textContent = enabled ? '停止动画' : '播放动画';
  };
  setAnimation(!reducedMotion.matches);
  toggle.hidden = false;
  toggle.addEventListener('click', () => setAnimation(!playing));
  reducedMotion.addEventListener('change', () => setAnimation(!reducedMotion.matches));
}
