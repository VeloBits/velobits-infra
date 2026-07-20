<#import "template.ftl" as layout>
<@layout.registrationLayout; section>
    <#if section = "header">
        ${msg("confirmLinkIdpTitle")}
    <#elseif section = "form">
        <#--
          FixMyText override: the base template also renders a "Review profile"
          (submitAction=updateProfile) button that reopens the editable
          "Update Account Information" page. We only want "Add to existing
          account", which routes through the flow's REQUIRED email/password
          verification step. Removing the review-profile escape hatch keeps
          account creation strictly one-identity-per-email: a social login whose
          email matches an existing account can only link (after proving
          ownership), never fork off a divergent profile. Safe because linking
          always demands downstream verification regardless of this button.
        -->
        <form id="kc-register-form" action="${url.loginAction}" method="post">
            <div class="${properties.kcFormGroupClass!}">
                <button type="submit" class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!} ${properties.kcButtonLargeClass!}" name="submitAction" id="linkAccount" value="linkAccount">${msg("confirmLinkIdpContinue", idpDisplayName)}</button>
            </div>
        </form>
    </#if>
</@layout.registrationLayout>
