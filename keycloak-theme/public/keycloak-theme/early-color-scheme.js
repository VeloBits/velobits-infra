/**
 * This file has been claimed for ownership from @oussemasahbeni/keycloakify-login-shadcn version 250004.0.24.
 * To relinquish ownership and restore this file to its original content, run the following command:
 * 
 * $ npx keycloakify own --path "early-color-scheme.js" --public --revert
 */

{
    const isDark = (() => {
        query_param: {
            const value = new URLSearchParams(location.search).get("dark");

            switch (value) {
                case "true":
                    return true;
                case "false":
                    return false;
                default:
                    break query_param;
            }
        }

        local_storage: {
            const value = localStorage.getItem("isDarkMode");

            if (value === null) {
                break local_storage;
            }

            switch (value) {
                case "dark":
                    return true;
                case "light":
                    return false;
                default:
                    break local_storage;
            }
        }

        // No stored preference: follow the OS color scheme
        // (keep in sync with login/shared/getColorScheme.ts).
        return matchMedia("(prefers-color-scheme: dark)").matches;
    })();

    {
        const element = document.createElement("style");

        element.innerHTML = `:root { color-scheme: ${isDark ? "dark" : "light"}; }`;

        document.head.appendChild(element);
    }

    if (isDark) {
        document.documentElement.classList.add("dark");
    }

    // Pre-paint background matching the velobits base palette to avoid a
    // flash before React applies the real tokens.
    document.documentElement.style.backgroundColor = isDark ? "#14170E" : "#FBFBF8";
}
