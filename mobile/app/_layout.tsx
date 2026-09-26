import { useFonts } from "expo-font";
import { type ErrorBoundaryProps, Stack } from "expo-router";
import { SQLiteProvider } from "expo-sqlite";
import { StatusBar } from "expo-status-bar";
import { Suspense } from "react";
import { View } from "react-native";
import { AuthProvider } from "../src/auth/provider";
import { PrimaryAction } from "../src/components/chrome";
import { ScreenMessage } from "../src/components/screen-message";
import { useOrientationPreference } from "../src/layout/orientation";
import { FieldSessionProvider } from "../src/session/provider";
import { initializeDatabase } from "../src/storage/observation-store";
import { SyncProvider } from "../src/sync/provider";
import { colors, space } from "../src/theme";
import { interFonts } from "../src/theme-fonts";

export function ErrorBoundary({ error, retry }: ErrorBoundaryProps) {
  return (
    <View style={{ flex: 1, paddingVertical: 48, backgroundColor: colors.bg }}>
      <ScreenMessage title="FieldMaps could not open" detail={error.message} />
      <View style={{ padding: space.wide }}>
        <PrimaryAction label="Try again" onPress={retry} />
      </View>
    </View>
  );
}

export default function RootLayout() {
  useOrientationPreference();
  // A missing face falls back to the system font rather than holding the collector shut.
  const [fontsReady, fontError] = useFonts(interFonts);
  if (!fontsReady && !fontError)
    return <ScreenMessage title="Opening FieldMaps" detail="Preparing your local workspace…" />;
  return (
    <Suspense
      fallback={
        <ScreenMessage title="Opening FieldMaps" detail="Preparing your local workspace…" />
      }
    >
      <SQLiteProvider databaseName="fieldmaps-shell.db" onInit={initializeDatabase} useSuspense>
        <AuthProvider>
          <SyncProvider>
            <FieldSessionProvider>
              <StatusBar style="light" />
              <Stack
                screenOptions={{
                  headerShown: false,
                  contentStyle: { backgroundColor: colors.bg },
                  animation: "fade",
                }}
              />
            </FieldSessionProvider>
          </SyncProvider>
        </AuthProvider>
      </SQLiteProvider>
    </Suspense>
  );
}
