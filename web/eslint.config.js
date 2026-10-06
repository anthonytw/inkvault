import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/", "node_modules/", "test/fixtures/", "test/golden/"] },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: { allowDefaultProject: ["eslint.config.js"] }, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      // The viewer never builds markup from strings (CSP: Trusted Types).
      "no-restricted-properties": ["error",
        { property: "innerHTML", message: "Build DOM nodes; never parse markup." },
        { property: "outerHTML", message: "Build DOM nodes; never parse markup." },
        { property: "insertAdjacentHTML", message: "Build DOM nodes; never parse markup." }],
      "no-eval": "error",
      "no-implied-eval": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
);
