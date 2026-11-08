import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Collectoo",
  description: "Plateforme de recouvrement amiable",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="fr" className="h-full antialiased">
      <body className="flex min-h-full flex-col">{children}</body>
    </html>
  );
}
