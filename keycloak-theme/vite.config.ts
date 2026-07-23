import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { keycloakify } from "keycloakify/vite-plugin";
import path from "node:path";
import { defineConfig } from "vite";

// https://vite.dev/config/
export default defineConfig({
    plugins: [
        react(),
        tailwindcss(),
        keycloakify({
            accountThemeImplementation: "none",
            themeName: "velobits",
            // Keycloak in this stack is pinned to 26.0.8 (docker-compose.yml),
            // which is served by the "all-other-versions" jar. The 22-to-25 jar
            // is disabled so CI and compose always reference one stable name.
            keycloakVersionTargets: {
                "22-to-25": false,
                "all-other-versions": "velobits.jar"
            },
            // Runtime knobs readable at kcContext.properties — overridable per
            // deployment via `environment:` on the keycloak service, no rebuild.
            environmentVariables: [
                { name: "SHADCN_THEME_LOGO_WHITE_URL", default: "" },
                { name: "SHADCN_THEME_LOGO_DARK_URL", default: "" },
                { name: "SHADCN_THEME_APP_NAME", default: "Velobits" },
                { name: "SHADCN_THEME_LAYOUT", default: "centered-card" },
                { name: "SHADCN_THEME_SIDE_IMAGE_URL", default: "" },
                { name: "SHADCN_THEME_PRESET", default: "neutral" },
                { name: "SHADCN_THEME_BASE", default: "neutral" },
                { name: "SHADCN_THEME_RADIUS", default: "default" },
                { name: "SHADCN_THEME_FONT", default: "geist" },
                { name: "SHADCN_THEME_PLACEHOLDER", default: "true" }
            ],
            startKeycloakOptions: {
                // Match the exact image the dev stack runs.
                dockerImage: "quay.io/keycloak/keycloak:26.0.8",
                realmJsonFilePath: "../keycloak/realm-export-dev.json"
            }
        })
    ],
    resolve: {
        alias: {
            "@": path.resolve(import.meta.dirname, "./src")
        }
    }
});
