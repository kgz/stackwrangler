# awsbox

> Category: Infrastructure console
> Surface: web

Dark operations console for learning AWS by doing the same jobs. Layout and nouns stay familiar. Color, type, and the mark do not.

## 1. Visual Theme & Atmosphere

awsbox is a dense dark console. A person who can find the service menu, the region, Create, and the resource table here can find them in the AWS console. The skin is not that console.

Kick kept Twitch's regions (follows, player, chat) and replaced the purple, the glitch mark, and the type. Do the same here. Keep the console skeleton. Replace the orange, the sky-blue links, the blue-charcoal chrome, the smile, and Ember.

The brand color is grey rose, used the way that console uses orange: one filled action, the mark, the active nav bar, the focus ring. Everything else is neutral charcoal and off-white. Buttons that carry the rose use near-black labels.

## 2. Color

Lead roles, in order:

- **Page background:** `#141414`
- **Border:** `#3A3A3A`
- **Foreground:** `#ECECEC`
- **Accent:** `#B48AA0`

Surfaces. Neutral charcoal. The rose does not tint the chrome.

- **Page:** `#141414` canvas behind the page
- **Chrome:** `#1C1C1C` top bar and service nav
- **Panel:** `#242424` table, cards, menus
- **Raised:** `#2E2E2E` hover row, dropdown, toolbar well
- **Selected wash:** `#2A2428` selected row and info alert fill

Copy.

- **Foreground:** `#ECECEC` titles and labels
- **Body copy:** `#C4C4C4` table cells and descriptions
- **Quiet:** `#8D8D8D` meta, placeholders, disabled
- **On accent:** `#1A1A1A` label on the filled action button

Action and links. Grey rose replaces orange and sky blue. Do not introduce a second brand hue.

- **Accent:** `#B48AA0` filled action, mark, focus
- **Accent hover:** `#C4A0B2`
- **Accent pressed:** `#9A7488`
- **Link:** `#E6D0DA` links and the current nav item
- **Link hover:** `#F3E6EC`

Status. None of these is the brand.

- **Danger:** `#E25B4A`
- **Warning:** `#E2B15A` sand, never the action color
- **Success:** `#3DDC8A`

Borders.

- **Border:** `#3A3A3A` panels and dividers
- **Hairline:** `#2A2A2A` splits inside a panel
- **Field edge:** `#5A5A5A` inputs and search

Never use `#FF9900`, `#EC7211`, `#42B4FF`, `#0F141A`, `#161D26`, or `#001129`.

## 3. Typography

UI face is Source Sans 3, then Segoe UI, sans-serif. Mono is Source Code Pro, then ui-monospace. Do not load Amazon Ember or an AWS icon font.

| Role | Size | Weight |
| --- | --- | --- |
| Page title | 20px | 600 |
| Section | 16px | 600 |
| Body | 14px | 400 |
| Control | 14px | 600 |
| Meta | 12px | 400 |
| ARN / id | 13px mono | 400 |

Sentence case. No display tracking. Line height 1.4 for UI, 1.5 for descriptions.

## 4. Spacing

4px base. Controls are 32px tall. Table rows are 40px. Page padding is 24px. The gap between toolbar clusters is 8px. Radius is 2px on controls and 4px on panels and menus. Do not round this into a marketing site.

## 5. Layout & Composition

Same jobs, same slots:

- Top bar: mark, services, search, utilities, region, account.
- Left nav: the service's own groups and labels.
- Page: title, short description, tabs, toolbar, table, pagination.
- Toolbar: filter and search on the left. The filled action on the right.
- Table: name first, location, date. Gear for columns. Pagination under the table.
- Empty state: one sentence and the same filled action.

Service nouns stay (bucket, object, region, access point). The product name in the chrome is awsbox, lowercase.

## 6. Components

Filled action. Background accent, label on-accent, 32px, radius 2px, weight 600. Hover lifts to accent hover. This is the only filled color button.

Quiet action. Transparent, 1px border, foreground label. Hover uses raised.

Icon button. 32px, no fill, quiet icon. Stroke 1.6, 16px glyph. Never a default-size SVG.

Nav item. 32px row. Active state is a 3px accent bar on the left, selected-wash background, link-colored label. Inactive labels are body copy.

Table. Panel background. Header meta at 12px, quiet color, not uppercase. Selected row uses selected wash. Links in the name column use the link color.

Search. Chrome field, field edge, 16px stroke icon, quiet placeholder.

Alert. Selected wash, 3px accent bar on the left, body copy. Not a blue banner.

Mark. 18px rounded square, 2px accent stroke, no fill, no smile, no arrow, no wordmark curve. A single vertical slot inside the square so it reads as a box.

## 7. Motion & Interaction

Color and border changes take 120ms. No bounce, no page-load animation. Focus is a 2px accent ring, offset 1px. Respect reduced motion by cutting the 120ms to 0.

## 8. Voice & Brand

Short, operational, the same verbs the console uses: create, delete, empty, copy ARN. Product name is awsbox. Never Amazon, never the smile, never "the cloud platform."

## 9. Anti-patterns

- Amazon smile, arrow logo, or wordmark.
- Orange as a brand, button, logo, or warning substitute.
- Sky-blue links.
- Blue-tinted charcoal chrome.
- Navy selected rows.
- Amazon Ember or the AWS icon set.
- A round, airy, marketing, or chat-app layout.
- A new information architecture. If a control exists in that console, put it in the same slot and paint it with these tokens.
- Kick green. The lesson is the shift, not their palette.
- An enabled button or link that does nothing (including toast-only). Not wired yet → `disabled` and `title="To implement"`. Will never ship → omit the control.
