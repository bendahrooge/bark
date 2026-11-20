// Register the cr iconset before any cr-icon-button upgrades and renders.
import 'chrome://resources/cr_elements/icons.html.js';
import 'chrome://resources/cr_elements/cr_button/cr_button.js';
import 'chrome://resources/cr_elements/cr_dialog/cr_dialog.js';
import 'chrome://resources/cr_elements/cr_icon_button/cr_icon_button.js';
import 'chrome://resources/cr_elements/cr_input/cr_input.js';
import 'chrome://resources/cr_elements/cr_shared_vars.css.js';

import {addWebUiListener, sendWithPromise} from 'chrome://resources/js/cr.js';

// Accent colors from SpaceTheme in apps/macos/src/SpaceEditor.swift.
const ACCENTS = {
  gray: '#777777',
  sage: '#58764E',
  clay: '#A5694F',
  lavender: '#7C68A6',
  ocean: '#477E9B',
  rose: '#AB607D',
  amber: '#947324',
  mint: '#3D8270',
  slate: '#64748A',
};

let state = {spaces: [], profiles: [], themes: []};

function $(id) {
  return document.getElementById(id);
}

function element(tag, properties = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(properties)) {
    if (key === 'class') {
      node.className = value;
    } else if (key === 'text') {
      node.textContent = value;
    } else if (key.startsWith('on')) {
      node.addEventListener(key.slice(2), value);
    } else if (key in node && key !== 'style') {
      node[key] = value;
    } else {
      node.setAttribute(key, value);
    }
  }
  node.append(...children);
  return node;
}

function capitalize(text) {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

// One emoji, matching Space.normalizedEmoji in the Swift sidebar.
function normalizedEmoji(input) {
  const value = input.trim();
  const graphemes = [...new Intl.Segmenter(undefined, {granularity: 'grapheme'}).segment(value)];
  if (graphemes.length !== 1 || [...value].length > 32) return null;
  return /\p{Emoji}/u.test(value) && /[^\x00-\x7f]/.test(value) ? value : null;
}

function profileName(id) {
  return state.profiles.find(profile => profile.id === id)?.name ?? '';
}

// Resolves true if the user confirms.
function confirmAction(title, body, label) {
  const dialog = $('deleteDialog');
  dialog.querySelector('[slot=title]').textContent = title;
  $('deleteBody').textContent = body;
  $('confirmDelete').textContent = label;
  return new Promise(resolve => {
    let confirmed = false;
    const confirm = () => {
      confirmed = true;
      dialog.close();
    };
    const cancel = () => dialog.cancel();
    $('confirmDelete').addEventListener('click', confirm, {once: true});
    $('cancelDelete').addEventListener('click', cancel, {once: true});
    dialog.addEventListener('close', () => {
      $('confirmDelete').removeEventListener('click', confirm);
      $('cancelDelete').removeEventListener('click', cancel);
      resolve(confirmed);
    }, {once: true});
    dialog.showModal();
  });
}

function saveSpace(space, changes) {
  const next = {...space, ...changes};
  chrome.send('updateSpace', [space.id, next.name, next.theme, next.emoji]);
}

function spaceRow(space, index, spaces) {
  const siblings = spaces.filter(other => other.profile === space.profile).length;

  const emoji = element('cr-input', {
    class: 'emoji',
    value: space.emoji,
    placeholder: '●',
    'aria-label': `Emoji for ${space.name}`,
    'data-focus-key': `emoji-${space.id}`,
    onchange: () => {
      // Clearing the field returns the space to its default dot.
      const value = emoji.value.trim() ? normalizedEmoji(emoji.value) : '';
      if (value !== null) {
        saveSpace(space, {emoji: value});
      } else {
        emoji.value = space.emoji;
      }
    },
  });

  const name = element('cr-input', {
    class: 'name',
    value: space.name,
    maxlength: 128,
    'aria-label': 'Space name',
    'data-focus-key': `name-${space.id}`,
    onchange: () => {
      const value = name.value.trim();
      if (value && value !== space.name) {
        saveSpace(space, {name: value});
      } else {
        name.value = space.name;
      }
    },
  });

  const profile = element('select', {
    'aria-label': `Profile for ${space.name}`,
    'data-focus-key': `profile-${space.id}`,
    title: 'Profile this space opens in',
    onchange: async () => {
      const target = profile.value;
      const moved = siblings > 1 && await confirmAction(
          'Move space to another profile?',
          `“${space.name}” will open in the “${profileName(target)}” profile. ` +
              'Its tabs reopen there, but sign-ins and site data stay with ' +
              `the “${profileName(space.profile)}” profile.`,
          'Move');
      if (moved) {
        chrome.send('setSpaceProfile', [space.id, target]);
      } else {
        profile.value = space.profile;
      }
    },
  }, state.profiles.map(item => element('option', {value: item.id, text: item.name})));
  profile.value = space.profile;
  if (siblings < 2) {
    profile.disabled = true;
    profile.title = `“${profileName(space.profile)}” needs at least one space`;
  }

  const move = (offset, icon, label) => element('cr-icon-button', {
    'iron-icon': icon,
    title: label,
    'aria-label': `${label}: ${space.name}`,
    'data-focus-key': `${icon}-${space.id}`,
    disabled: !spaces[index + offset],
    onclick: () => chrome.send('swapSpaces', [space.id, spaces[index + offset].id]),
  });

  const remove = element('cr-icon-button', {
    'iron-icon': 'cr:delete',
    title: state.spaces.length < 2 ? 'Keep at least one space' : 'Delete space',
    'aria-label': `Delete ${space.name}`,
    'data-focus-key': `delete-${space.id}`,
    disabled: state.spaces.length < 2,
    onclick: async () => {
      if (await confirmAction('Delete space?',
              siblings < 2
                  ? `“${space.name}” is removed from the sidebar. Its profile, tabs, sign-ins, and saved data are kept. To use them again, create a space in this profile.`
                  : `“${space.name}” is removed from the sidebar. Its open tabs move to another space in the “${profileName(space.profile)}” profile.`,
              'Delete')) {
        chrome.send('deleteSpace', [space.id]);
      }
    },
  });

  const colors = element('div', {class: 'colors', role: 'radiogroup', 'aria-label': 'Color'},
      state.themes.map(theme => element('button', {
        class: 'swatch',
        role: 'radio',
        title: capitalize(theme),
        'aria-label': capitalize(theme),
        'aria-checked': String(theme === space.theme),
        'data-focus-key': `color-${theme}-${space.id}`,
        style: `background-color: ${ACCENTS[theme] ?? ACCENTS.gray}`,
        onclick: () => {
          if (theme !== space.theme) saveSpace(space, {theme});
        },
      })));

  return element('div', {class: 'row space'}, [
    element('div', {class: 'space-main'}, [
      emoji, name, profile,
      element('div', {class: 'actions'}, [
        move(-1, 'cr:keyboard-arrow-up', 'Move up'),
        move(1, 'cr:keyboard-arrow-down', 'Move down'),
        remove,
      ]),
    ]),
    colors,
  ]);
}

function profileRow(profile) {
  const name = element('cr-input', {
    class: 'name',
    value: profile.name,
    maxlength: 128,
    'aria-label': 'Profile name',
    'data-focus-key': `profile-name-${profile.id}`,
    onchange: () => {
      const value = name.value.trim();
      if (value && value !== profile.name) {
        chrome.send('renameProfile', [profile.id, value]);
      } else {
        name.value = profile.name;
      }
    },
  });
  const count = profile.spaces === 1 ? '1 space' : `${profile.spaces} spaces`;
  const row = element('div', {class: 'row profile'}, [
    name,
    element('span', {class: 'count', text: count}),
  ]);
  if (state.canDeleteProfiles) {
    row.append(element('cr-icon-button', {
      'iron-icon': 'cr:delete',
      title: 'Delete profile',
      'aria-label': `Delete profile ${profile.name}`,
      'data-focus-key': `delete-profile-${profile.id}`,
      onclick: async () => {
        const message = 'This permanently deletes this profile’s Spaces, tabs, bookmarks, saved passwords, and browsing history from this Mac.';
        const detail = state.profiles.length === 1 ? message + ' Bark will open a new, empty profile.' : message;
        if (await confirmAction(`Delete “${profile.name}”?`, detail, 'Delete Profile')) {
          chrome.send('deleteProfile', [profile.id]);
        }
      },
    }));
  }
  return row;
}

function render() {
  // Re-rendering replaces the controls, so keep keyboard focus in place.
  const focused = document.activeElement?.dataset?.focusKey;

  const spaces = $('spaces');
  spaces.replaceChildren(...state.spaces.map(spaceRow));
  if (!state.spaces.length) {
    spaces.append(element('div', {class: 'empty', text: 'No spaces yet.'}));
  }
  $('profiles').replaceChildren(...state.profiles.map(profileRow));
  $('factory-reset').hidden = !state.canFactoryReset;

  if (focused) {
    const target = document.querySelector(`[data-focus-key="${CSS.escape(focused)}"]`);
    if (target?.focusInput) {
      target.focusInput();
    } else {
      target?.focus();
    }
  }
}

function update(next) {
  state = next;
  render();
}

function addProfile() {
  const input = $('newProfile');
  const name = input.value.trim();
  if (!name) return;
  chrome.send('createProfile', [name]);
  input.value = '';
  $('addProfile').disabled = true;
}

$('back').addEventListener('click', () => {
  location.href = 'chrome://settings';
});
$('newProfile').addEventListener('input', () => {
  $('addProfile').disabled = !$('newProfile').value.trim();
});
// cr-input keeps its <input> in a shadow root, so Enter cannot submit a form.
$('newProfile').addEventListener('keydown', event => {
  if (event.key === 'Enter') addProfile();
});
$('addProfile').addEventListener('click', addProfile);

async function showFactoryReset() {
  if (!state.canFactoryReset || $('resetBark').disabled || $('deleteDialog').open) return;
  const confirmed = await confirmAction('Reset Bark to factory settings?',
      'Bark will close every window and permanently erase all local spaces, profiles, tabs, ' +
      'bookmarks, saved passwords, history, extensions, site data, and settings. ' +
      'Files saved outside Bark’s data folder stay on disk. The next time you open Bark, it will have a fresh profile.',
      'Erase and quit');
  if (!confirmed) return;
  $('resetBark').disabled = true;
  $('resetStatus').textContent = 'Preparing to erase data and quit Bark…';
  try {
    if (await sendWithPromise('factoryResetRequiringGesture')) return;
  } catch {}
  $('resetBark').disabled = false;
  $('resetStatus').textContent = 'Bark couldn’t start the reset. Check that its data folder is writable and try again.';
}

$('resetBark').addEventListener('click', showFactoryReset);
function openResetFromSettings() {
  if (location.hash === '#factory-reset' && state.canFactoryReset) {
    $('resetBark').focus();
    showFactoryReset();
  }
}
window.addEventListener('hashchange', openResetFromSettings);
addWebUiListener('state-changed', update);
sendWithPromise('getState').then(next => {
  update(next);
  openResetFromSettings();
});
