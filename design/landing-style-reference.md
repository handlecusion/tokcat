# Scale — Style Reference
> Midnight Command Center: An expanse of polished dark surfaces, illuminated by precise white text and the occasional shimmer of an iridescent, almost holographic, light.

**Theme:** dark

This design system evokes a sense of deep, sophisticated technology within a secure, high-contrast environment. The dominant ultra-dark palette, punctuated by crisp white text and a subtle, iridescent gradient, creates an atmosphere of serious innovation. Minimal use of vibrant colors ensures that any color interaction is highly deliberate, like an indicator light on a complex machine. Typography features whisper-light headlines, conveying authority through understated elegance against the stark backdrop.

## Tokens — Colors

| Name | Value | Token | Role |
|------|-------|-------|------|
| Deep Space | `#000000` | `--color-deep-space` | Primary page background, card backgrounds, creating a high-contrast canvas. |
| Ghost White | `#ffffff` | `--color-ghost-white` | Primary text color for headlines and body text, accentuating information against the dark background. Also used for borders on interactive elements. |
| Iron Slate | `#a1a1a1` | `--color-iron-slate` | Secondary text for less prominent information, active navigation links, and subtle borders. |
| Halo Pale | `#f4f0ff` | `--color-halo-pale` | Subtle, near-white text for secondary links and body text in less prominent sections. This provides a very soft contrast against black. |
| Shadow Tint | `#020202` | `--color-shadow-tint` | Subtle shadows and background for elements that need a touch more depth than pure black. |
| Subtle Gray | `#e5e5e5` | `--color-subtle-gray` | Text and icon color, for details that require slightly less prominence than Ghost White. |
| Iridescent Glow | `#bbdef2` | `--color-iridescent-glow` | Backgrounds of geometric abstract shapes, providing a luminous, futuristic visual accent. |
| Spectrum Flare | `#d1aad7` | `--color-spectrum-flare` | Used for the lighter parts of the iridescent gradient, giving it a soft, ethereal quality. |
| Vivid Crimson | `#ff6467` | `--color-vivid-crimson` | Indicator or accent background, used sparingly to draw attention. |
| Goldenrod | `#ffd600` | `--color-goldenrod` | Indicator or accent background, used sparingly for specific highlight. |
| Emerald Green | `#72ce7b` | `--color-emerald-green` | Indicator or accent background, used sparingly for specific highlight. |
| Dark Rainbow Gradient | `linear-gradient(to right bottom in oklab, rgb(154, 154, 154) 0%, rgb(26, 26, 26) 50%, rgb(106, 106, 106) 100%)` | `--color-dark-rainbow-gradient` | Used for highly stylized, abstract background elements, providing a subtle shimmer that hints at dimension and data flow. |

## Tokens — Typography

### Inter — Standard body text, navigation elements, buttons, and various UI labels. Its wide range of sizes and normal weight support the bulk of content, ensuring readability without distracting from the main brand typography. · `--font-inter`
- **Substitute:** system-ui, sans-serif
- **Weights:** 400, 500
- **Sizes:** 12px, 14px, 16px, 18px, 20px
- **Line height:** 1.33, 1.43, 1.50, 1.56, 1.60, 1.65, 1.71
- **Letter spacing:** 0.10em at 12px, 0.286em at 14px, 0.333em at 16px
- **Role:** Standard body text, navigation elements, buttons, and various UI labels. Its wide range of sizes and normal weight support the bulk of content, ensuring readability without distracting from the main brand typography.

### aeonik — Primary display font for headlines and sub-headlines. The signature weight 300 for large sizes creates a whisper-quiet yet authoritative tone, prioritizing understatement over visual shouting, which is distinctive for a high-tech brand. · `--font-aeonik`
- **Substitute:** Montserrat, sans-serif
- **Weights:** 300, 400
- **Sizes:** 24px, 26px, 36px, 48px, 72px, 89px
- **Line height:** 1.00, 1.11, 1.13, 1.23, 1.25, 1.33, 1.67
- **Letter spacing:** -0.01em
- **Role:** Primary display font for headlines and sub-headlines. The signature weight 300 for large sizes creates a whisper-quiet yet authoritative tone, prioritizing understatement over visual shouting, which is distinctive for a high-tech brand.

### geist — Used for small, descriptive text, often for labels or details that require a slightly technical or precise feel. The wider letter-spacing at smaller sizes improves legibility. · `--font-geist`
- **Substitute:** Source Code Pro, monospace
- **Weights:** 400
- **Sizes:** 12px, 14px
- **Line height:** 1.43, 1.50, 2.00
- **Letter spacing:** 0.071em at 14px, 0.083em at 12px
- **Role:** Used for small, descriptive text, often for labels or details that require a slightly technical or precise feel. The wider letter-spacing at smaller sizes improves legibility.

## Tokens — Spacing & Shapes

**Base unit:** 8px

**Density:** comfortable

### Spacing Scale

| Name | Value | Token |
|------|-------|-------|
| 8 | 8px | `--spacing-8` |
| 16 | 16px | `--spacing-16` |
| 24 | 24px | `--spacing-24` |
| 32 | 32px | `--spacing-32` |
| 40 | 40px | `--spacing-40` |
| 48 | 48px | `--spacing-48` |
| 64 | 64px | `--spacing-64` |
| 72 | 72px | `--spacing-72` |
| 80 | 80px | `--spacing-80` |
| 192 | 192px | `--spacing-192` |
| 224 | 224px | `--spacing-224` |

### Border Radius

| Element | Value |
|---------|-------|
| links | 16px |
| lists | 4px |
| default | 8px |

### Shadows

| Name | Value | Token |
|------|-------|-------|
| subtle | `rgba(255, 255, 255, 0.1) 0px 1px 1px 0px inset` | `--shadow-subtle` |

### Layout

- **Section gap:** 32px
- **Card padding:** 24px
- **Element gap:** 8px

## Components

### Navigation Link
**Role:** Primary navigation item

White text (Ghost White #ffffff) on a transparent background, 4px vertical padding and 0px horizontal padding. Underlines appear on hover/active states, with no distinct border radius. Font is Inter 16px weight 400.

### Secondary Hero Button (Text Link)
**Role:** Secondary call to action

Ghost White #ffffff text on a transparent background, with an arrow icon. Font is Inter 16px weight 400. Padding of 17px horizontal and 12px vertical. No explicit border or radius.

### Feature Card
**Role:** Content container for features

Implicitly dark background (likely Deep Space #000000 or Shadow Tint #020202) with rounded corners (8px). Text is typically Ghost White #ffffff for headings and Halo Pale #f4f0ff or Iron Slate #a1a1a1 for body copy. Contains abstract image elements.

## Do's and Don'ts

### Do
- Prioritize Deep Space (#000000) for backgrounds and Ghost White (#ffffff) for primary text to maintain high contrast and sophistication.
- Use aeonik font with weight 300 for all large headlines (48px and above) to achieve an understated, authoritative tone.
- Apply Iron Slate (#a1a1a1) for secondary text and active navigation items to provide subtle differentiation without losing readability.
- Employ the Iridescent Glow (#bbdef2) and Spectrum Flare (#d1aad7) gradient only for abstract geometric elements or distinctive brand accents, not for interactive components.
- Maintain generous vertical spacing between sections, using multiples of 32px to provide breathing room on the dark canvas.
- Use 8px border radius as the default for most containers and images, with 16px for larger interactive links, and 4px for smaller list items.

### Don't
- Do not introduce highly saturated colors for general UI elements; reserve them for specific accent indicators if truly necessary.
- Avoid heavy drop shadows; the design relies on subtle background variations and text contrast for depth, with minimal inset shadows.
- Do not use aeonik font for body text; reserve it for headlines and maintain its distinctive impact.
- Avoid excessive use of Halo Pale (#f4f0ff) for primary content; its low contrast is intended for secondary or subtle elements.
- Do not use generic system borders; interactive elements should feature white or subtle gray borders for consistency.
- Avoid dense information blocks; use ample White Space, especially on dark backgrounds, to enhance clarity and visual weight.

## Imagery

The visual language is characterized by abstract, geometric 3D renders with iridescent, gradient-filled surfaces (Iridescent Glow #bbdef2, Spectrum Flare #d1aad7). These graphics are contained and serve as decorative visual anchors in the dark space, emphasizing a futuristic, AI-driven aesthetic. Photography is minimal, if present, and product screenshots are likely stylized to fit the dark theme. Icons are typically white or subtle gray, outlined, reinforcing the clean, high-tech identity. The imagery acts primarily as atmospheric branding and conceptual illustration, occupying significant visual space relative to text in some hero sections, but is not dense or overwhelming.

## Layout

The page primarily uses a max-width contained layout, centered on the screen, though the hero section spans full-bleed with its striking dark background and large, centered typography. The hero features a simple, prominent headline over a dark void, balanced by abstract 3D graphics on one side. Subsequent sections predominantly follow a vertical stacking pattern with consistent Deep Space (#000000) backgrounds, occasionally introducing subtly different dark shades for content blocks. Content is often presented in centered stacks or simple two-column arrangements (text alongside an image/graphic). Navigation is a sticky top bar with minimal links and clear call-to-action buttons. Vertical spacing between sections is generous (32px and above), creating a spacious and unhurried rhythm.

## Agent Prompt Guide

### Quick Color Reference
- Text (Primary): #ffffff (Ghost White)
- Background (Primary): #000000 (Deep Space)
- CTA Button Background: transparent
- CTA Button Border: #ffffff (Ghost White)
- Accent Graphic: #bbdef2 (Iridescent Glow)

### Example Component Prompts
1. Create a Hero Section: Full-width Deep Space #000000 background. Centered headline 'Breakthrough AI from Data to Deployment' using aeonik 89px weight 300, Ghost White #ffffff, letter-spacing -0.01em. Subtext 'Scale delivers proven data...' using Inter 20px weight 400, Halo Pale #f4f0ff, line-height 1.6. Two buttons: 'Book a Demo' with Ghost White #ffffff text, transparent background, 1px Ghost White #ffffff border, 17px horizontal, 12px vertical padding; and 'Build AI' with Ghost White #ffffff text, transparent background, no border, 17px horizontal, 12px vertical padding. Include an abstract geometric graphic using Iridescent Glow #bbdef2 and Spectrum Flare #d1aad7 colors on the right side.
2. Design a Navigation Bar: Deep Space #000000 background, 59-147px height. Logo 'Scale' using Inter 24px weight 500, Ghost White #ffffff. Navigation links 'Products', 'Research', 'Enterprise', 'Government', 'Resources' using Inter 16px weight 400, Ghost White #ffffff, white on hover, 4px vertical padding, 0px horizontal padding. Right-aligned buttons 'Book a Demo' (Ghost White #ffffff text, 1px Ghost White #ffffff border, transparent background) and 'Log In' (Ghost White #ffffff text, transparent background, no border).
3. Create a Testimonial Block: Deep Space #000000 background. Headline 'We have changed the game...' using aeonik 48px weight 300, Ghost White #ffffff, letter-spacing -0.01em. A testimonial card: 8px border-radius, transparent background with inset shadow rgba(255, 255, 255, 0.1) 0px 1px 1px 0px inset. Quote text '"We partnered with Scale AI..."' using Inter 20px weight 400, Ghost White #ffffff. Attribution 'Mark Zuckerberg' using Inter 16px weight 500, Halo Pale #f4f0ff.

## Similar Brands

- **OpenAI** — Shares a sophisticated, dark-mode focused UI with strong typography and minimal, controlled use of color, conveying high-tech and serious intent.
- **Databricks** — Employs an enterprise-grade dark theme, often featuring abstract geometric visuals and a clear hierarchy emphasized by text weight and color contrast.
- **Palantir** — Utilizes a dark, high-contrast interface with an emphasis on data visualization and a controlled, almost austere aesthetic, communicating complex capabilities.
- **Anthropic** — Features a clean, minimalist dark aesthetic with a focus on core information, using typography and subtle grays to establish hierarchy.

## Quick Start

### CSS Custom Properties

```css
:root {
  /* Colors */
  --color-deep-space: #000000;
  --color-ghost-white: #ffffff;
  --color-iron-slate: #a1a1a1;
  --color-halo-pale: #f4f0ff;
  --color-shadow-tint: #020202;
  --color-subtle-gray: #e5e5e5;
  --color-iridescent-glow: #bbdef2;
  --color-spectrum-flare: #d1aad7;
  --color-vivid-crimson: #ff6467;
  --color-goldenrod: #ffd600;
  --color-emerald-green: #72ce7b;
  --color-dark-rainbow-gradient: #9a9a9a;
  --gradient-dark-rainbow-gradient: linear-gradient(to right bottom in oklab, rgb(154, 154, 154) 0%, rgb(26, 26, 26) 50%, rgb(106, 106, 106) 100%);

  /* Typography — Font Families */
  --font-inter: 'Inter', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-aeonik: 'aeonik', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-geist: 'geist', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;

  /* Typography — Scale */
  --text-xs: 12px;
  --leading-xs: 2;
  --text-sm: 14px;
  --leading-sm: 1.43;
  --text-base: 16px;
  --leading-base: 1.5;
  --text-lg: 18px;
  --leading-lg: 1.65;
  --text-xl: 20px;
  --leading-xl: 1.6;
  --text-2xl: 24px;
  --leading-2xl: 1.67;
  --text-2xl-2: 26px;
  --leading-2xl-2: 1.23;
  --text-4xl: 36px;
  --leading-4xl: 1.25;
  --text-5xl: 48px;
  --leading-5xl: 1.25;
  --text-5xl-2: 72px;
  --leading-5xl-2: 1.11;
  --text-5xl-3: 89px;
  --leading-5xl-3: 1;

  /* Typography — Weights */
  --font-weight-light: 300;
  --font-weight-regular: 400;
  --font-weight-medium: 500;

  /* Spacing */
  --spacing-unit: 8px;
  --spacing-8: 8px;
  --spacing-16: 16px;
  --spacing-24: 24px;
  --spacing-32: 32px;
  --spacing-40: 40px;
  --spacing-48: 48px;
  --spacing-64: 64px;
  --spacing-72: 72px;
  --spacing-80: 80px;
  --spacing-192: 192px;
  --spacing-224: 224px;

  /* Layout */
  --section-gap: 32px;
  --card-padding: 24px;
  --element-gap: 8px;

  /* Border Radius */
  --radius-md: 4px;
  --radius-lg: 8px;
  --radius-xl: 12px;
  --radius-2xl: 16px;

  /* Named Radii */
  --radius-links: 16px;
  --radius-lists: 4px;
  --radius-default: 8px;

  /* Shadows */
  --shadow-subtle: rgba(255, 255, 255, 0.1) 0px 1px 1px 0px inset;
}
```

### Tailwind v4

```css
@theme {
  /* Colors */
  --color-deep-space: #000000;
  --color-ghost-white: #ffffff;
  --color-iron-slate: #a1a1a1;
  --color-halo-pale: #f4f0ff;
  --color-shadow-tint: #020202;
  --color-subtle-gray: #e5e5e5;
  --color-iridescent-glow: #bbdef2;
  --color-spectrum-flare: #d1aad7;
  --color-vivid-crimson: #ff6467;
  --color-goldenrod: #ffd600;
  --color-emerald-green: #72ce7b;
  --color-dark-rainbow-gradient: #9a9a9a;

  /* Typography */
  --font-inter: 'Inter', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-aeonik: 'aeonik', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-geist: 'geist', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;

  /* Typography — Scale */
  --text-xs: 12px;
  --leading-xs: 2;
  --text-sm: 14px;
  --leading-sm: 1.43;
  --text-base: 16px;
  --leading-base: 1.5;
  --text-lg: 18px;
  --leading-lg: 1.65;
  --text-xl: 20px;
  --leading-xl: 1.6;
  --text-2xl: 24px;
  --leading-2xl: 1.67;
  --text-2xl-2: 26px;
  --leading-2xl-2: 1.23;
  --text-4xl: 36px;
  --leading-4xl: 1.25;
  --text-5xl: 48px;
  --leading-5xl: 1.25;
  --text-5xl-2: 72px;
  --leading-5xl-2: 1.11;
  --text-5xl-3: 89px;
  --leading-5xl-3: 1;

  /* Spacing */
  --spacing-8: 8px;
  --spacing-16: 16px;
  --spacing-24: 24px;
  --spacing-32: 32px;
  --spacing-40: 40px;
  --spacing-48: 48px;
  --spacing-64: 64px;
  --spacing-72: 72px;
  --spacing-80: 80px;
  --spacing-192: 192px;
  --spacing-224: 224px;

  /* Border Radius */
  --radius-md: 4px;
  --radius-lg: 8px;
  --radius-xl: 12px;
  --radius-2xl: 16px;

  /* Shadows */
  --shadow-subtle: rgba(255, 255, 255, 0.1) 0px 1px 1px 0px inset;
}
```
