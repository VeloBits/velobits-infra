/**
 * This file has been claimed for ownership from @oussemasahbeni/keycloakify-login-shadcn version 250004.0.24.
 * To relinquish ownership and restore this file to its original content, run the following command:
 *
 * $ npx keycloakify own --path "login/i18n.ts" --revert
 */

import { i18nBuilder } from "@keycloakify/login-ui/i18n";
import type { ThemeName } from "../kc.gen";

/**
 * @see: https://docs.keycloakify.dev/features/i18n
 *
 * en-only on purpose: the Velobits realms don't enable internationalization
 * (no supportedLocales in the realm exports), and the legacy fixmytext theme
 * only shipped messages_en.properties. Standard Keycloak keys keep their
 * upstream translations in every locale; the custom keys below fall back to
 * English if a locale is ever enabled. The upstream 30-locale version of this
 * file can be restored with the --revert command above, or read from
 * node_modules/@oussemasahbeni/keycloakify-login-shadcn.
 *
 * These values must stay statically analyzable (inline literals, no imports):
 * Keycloakify compiles them into messages_*.properties at build time so
 * server-rendered messages match.
 */
const { I18nProvider, useI18n } = i18nBuilder
    .withThemeName<ThemeName>()
    .withCustomTranslations({
        en: {
            welcomeMessage:
                "Welcome to Velobits - one account for every VeloBits product.",
            // Ported from the legacy fixmytext theme's messages_en.properties:
            // short, product-neutral auth wording.
            loginAccountTitle: "Sign in",
            loginTitle: "Sign in",
            registerTitle: "Sign up",
            noAccount: "Don't have an account?",
            doLogIn: "Sign in",
            doRegister: "Sign up",
            emailForgotTitle: "Reset password",
            emailInstruction: "Enter your email and we'll send you a reset link.",
            backToLogin: "Back to sign in",
            doCancel: "Cancel",
            // Kept from the upstream shadcn theme (custom keys it renders).
            "organization.selectTitle": "Choose Your Organization",
            "organization.pickPlaceholder": "Pick an organization to continue",
            "identity-provider-login-last-used": "Last",
            attemptedUsernameLoggingInAs: "Logging in as",
            usernamePlaceholder: "Enter your username",
            usernameOrEmailPlaceholder: "Enter your username or email",
            emailPlaceholder: "Enter your email",
            passwordPlaceholder: "Enter your password",
            newPasswordPlaceholder: "Enter your new password",
            confirmPasswordPlaceholder: "Confirm your password"
        }
    })
    .build();

export { I18nProvider, useI18n };
