/**
 * This file has been claimed for ownership from @oussemasahbeni/keycloakify-login-shadcn version 250004.0.24.
 * To relinquish ownership and restore this file to its original content, run the following command:
 *
 * $ npx keycloakify own --path "login/components/Template/TemplateTopBar.tsx" --revert
 */

import { useI18n } from "../../i18n";
import { Languages } from "../ui/Langauges";

/**
 * Velobits: the upstream home button and dark/light ModeToggle are removed -
 * the color scheme follows the OS (see login/shared/getColorScheme.ts) and
 * the login flow shouldn't offer an exit to the client base URL. Only the
 * language switcher remains, and only when the realm enables >1 locale.
 */
export function TemplateTopBar() {
    const { enabledLanguages } = useI18n();

    return (
        <div className="absolute inset-x-4 top-4 z-20 flex items-center gap-2">
            {enabledLanguages.length > 1 && <Languages />}
        </div>
    );
}
