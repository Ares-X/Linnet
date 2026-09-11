const tabs = [...document.querySelectorAll('[role="tab"]')];

function selectTab(tab, focus = false) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
  if (focus) tab.focus();
}

for (const tab of tabs) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (event) => {
    const current = tabs.indexOf(tab);
    let next;
    if (event.key === 'ArrowRight') next = (current + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (current - 1 + tabs.length) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    selectTab(tabs[next], true);
  });
}

const copyButton = document.getElementById('copy-command');
const copyStatus = document.getElementById('copy-status');
copyButton.addEventListener('click', async () => {
  const command = document.getElementById('verify-command').textContent;
  try {
    await navigator.clipboard.writeText(command);
    copyStatus.textContent = '命令已复制。';
  } catch {
    copyStatus.textContent = '未能访问剪贴板，请选中上方命令手动复制。';
  }
});
