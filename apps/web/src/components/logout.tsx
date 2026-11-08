export function LogoutButton() {
  return (
    <form action="/deconnexion" method="post">
      <button type="submit" className="text-sm underline underline-offset-4">
        Se déconnecter
      </button>
    </form>
  );
}
