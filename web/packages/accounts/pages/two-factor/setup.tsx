import { CodeBlock } from "@/accounts/components/CodeBlock";
import { Verify2FACodeForm } from "@/accounts/components/Verify2FACodeForm";
import { appHomeRoute } from "@/accounts/services/redirect";
import type { TwoFactorSecret } from "@/accounts/services/user";
import { enableTwoFactor, setupTwoFactor } from "@/accounts/services/user";
import { CenteredFill } from "@/base/components/containers";
import { LinkButton } from "@/base/components/LinkButton";
import { ActivityIndicator } from "@/base/components/mui/ActivityIndicator";
import { FocusVisibleButton } from "@/base/components/mui/FocusVisibleButton";
import { encryptWithRecoveryKey } from "@ente/shared/crypto/helpers";
import { getData, LS_KEYS, setLSUser } from "@ente/shared/storage/localStorage";
import { Paper, Stack, styled, Typography } from "@mui/material";
import { t } from "i18next";
import { useRouter } from "next/router";
import React, { useEffect, useState } from "react";

const Page: React.FC = () => {
    const [twoFactorSecret, setTwoFactorSecret] = useState<
        TwoFactorSecret | undefined
    >();

    const router = useRouter();

    useEffect(() => {
        void setupTwoFactor().then(setTwoFactorSecret);
    }, []);

    const handleSubmit = async (otp: string) => {
        const {
            encryptedData: encryptedTwoFactorSecret,
            nonce: twoFactorSecretDecryptionNonce,
        } = await encryptWithRecoveryKey(twoFactorSecret!.secretCode);
        await enableTwoFactor({
            code: otp,
            encryptedTwoFactorSecret,
            twoFactorSecretDecryptionNonce,
        });
        await setLSUser({
            ...getData(LS_KEYS.USER),
            isTwoFactorEnabled: true,
        });
        void router.push(appHomeRoute);
    };

    return (
        <Stack sx={{ minHeight: "100svh" }}>
            <CenteredFill>
                <ContentsPaper>
                    <Typography variant="h5" sx={{ textAlign: "center" }}>
                        {t("two_factor")}
                    </Typography>
                    <Instructions twoFactorSecret={twoFactorSecret} />
                    <Verify2FACodeForm
                        onSubmit={handleSubmit}
                        submitButtonText={t("enable")}
                    />
                    <Stack sx={{ alignItems: "center" }}>
                        <FocusVisibleButton
                            variant="text"
                            onClick={router.back}
                        >
                            {t("go_back")}
                        </FocusVisibleButton>
                    </Stack>
                </ContentsPaper>
            </CenteredFill>
        </Stack>
    );
};

export default Page;

const ContentsPaper = styled(Paper)(({ theme }) => ({
    marginBlock: theme.spacing(2),
    padding: theme.spacing(4, 2),
    // Wide enough to fit the QR code secret in one line under default settings.
    width: "min(440px, 95vw)",
    display: "flex",
    flexDirection: "column",
    gap: theme.spacing(4),
}));

interface InstructionsProps {
    twoFactorSecret: TwoFactorSecret | undefined;
}

const Instructions: React.FC<InstructionsProps> = ({ twoFactorSecret }) => {
    const [setupMode, setSetupMode] = useState<"qr" | "manual">("qr");

    return (
        <Stack sx={{ gap: 3, alignItems: "center" }}>
            {setupMode == "qr" ? (
                <SetupQRMode
                    twoFactorSecret={twoFactorSecret}
                    onChangeMode={() => setSetupMode("manual")}
                />
            ) : (
                <SetupManualMode
                    twoFactorSecret={twoFactorSecret}
                    onChangeMode={() => setSetupMode("qr")}
                />
            )}
        </Stack>
    );
};

interface SetupManualModeProps {
    twoFactorSecret: TwoFactorSecret | undefined;
    onChangeMode: () => void;
}

const SetupManualMode: React.FC<SetupManualModeProps> = ({
    twoFactorSecret,
    onChangeMode,
}) => (
    <>
        <Typography sx={{ color: "text.muted", textAlign: "center", px: 2 }}>
            {t("two_factor_manual_entry_message")}
        </Typography>
        <CodeBlock code={twoFactorSecret?.secretCode} />
        <LinkButton onClick={onChangeMode}>{t("scan_qr_title")}</LinkButton>
    </>
);

interface SetupQRModeProps {
    twoFactorSecret?: TwoFactorSecret;
    onChangeMode: () => void;
}

const SetupQRMode: React.FC<SetupQRModeProps> = ({
    twoFactorSecret,
    onChangeMode,
}) => (
    <>
        <Typography sx={{ color: "text.muted", textAlign: "center" }}>
            {t("two_factor_qr_help")}
        </Typography>
        {!twoFactorSecret ? (
            <LoadingQRCode>
                <ActivityIndicator />
            </LoadingQRCode>
        ) : (
            <QRCode src={`data:image/png;base64,${twoFactorSecret?.qrCode}`} />
        )}
        <LinkButton onClick={onChangeMode}>
            {t("two_factor_manual_entry_title")}
        </LinkButton>
    </>
);

const QRCode = styled("img")(`
    width: 200px;
    height: 200px;
`);

const LoadingQRCode = styled(Stack)(
    ({ theme }) => `
    width: 200px;
    height: 200px;
    border: 1px solid ${theme.vars.palette.stroke.muted};
    align-items: center;
    justify-content: center;
   `,
);
