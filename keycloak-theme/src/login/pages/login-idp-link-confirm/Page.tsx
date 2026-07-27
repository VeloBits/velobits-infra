/**
 * This file has been claimed for ownership from @oussemasahbeni/keycloakify-login-shadcn version 250004.0.24.
 * To relinquish ownership and restore this file to its original content, run the following command:
 * 
 * $ npx keycloakify own --path "login/pages/login-idp-link-confirm/Page.tsx" --revert
 */

import { Button } from "@/components/ui/button";
import { useI18n } from "@/login/i18n";
import { useKcContext } from "@/login/KcContext";
import { assert } from "tsafe/assert";
import { Template } from "../../components/Template";

export function Page() {
    const { kcContext } = useKcContext();
    assert(kcContext.pageId === "login-idp-link-confirm.ftl");

    const { msg } = useI18n();

    return (
        <Template headerNode={msg("confirmLinkIdpTitle")}>
            {/*
              Velobits override: upstream also renders a "Review profile"
              (submitAction=updateProfile) button that reopens the editable
              "Update Account Information" page. We only want "Add to existing
              account", which routes through the flow's REQUIRED email/password
              verification step. Removing the review-profile escape hatch keeps
              account creation strictly one-identity-per-email: a social login
              whose email matches an existing account can only link (after
              proving ownership), never fork off a divergent profile. Safe
              because linking always demands downstream verification.
            */}
            <form id="kc-register-form" action={kcContext.url.loginAction} method="post">
                <Button
                    type="submit"
                    className="w-full"
                    name="submitAction"
                    id="linkAccount"
                    value="linkAccount"
                >
                    {msg("confirmLinkIdpContinue", kcContext.idpAlias)}
                </Button>
            </form>
        </Template>
    );
}
