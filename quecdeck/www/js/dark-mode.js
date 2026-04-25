const darkModeToggle = document.getElementById('darkModeToggle');
const html = document.querySelector('html');

const setTheme = (theme) => {
  html.setAttribute('data-bs-theme', theme);
  darkModeToggle.innerHTML = theme === 'dark'
    ? '☀️ Light'
    : '🌙 Dark';
  localStorage.setItem('theme', theme);
};

const toggleDarkMode = () => {
  setTheme(html.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark');
};

const storedTheme = localStorage.getItem('theme') || 'dark';
setTheme(storedTheme);

darkModeToggle.addEventListener('click', toggleDarkMode);