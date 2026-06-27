// @ts-check
import { defineConfig } from 'astro/config';

// Amaranth ships from a GitHub *project* Pages site, so everything is served
// under /amaranth/ (same site that hosts the Sparkle appcast.xml). `base` keeps
// asset URLs correct; reference local assets through import.meta.env.BASE_URL.
export default defineConfig({
  site: 'https://zaius.github.io',
  base: '/amaranth',
  trailingSlash: 'ignore',
  build: {
    // Plain .html files (no /page/index.html dirs) — tidy for a one-pager.
    format: 'file',
  },
});
