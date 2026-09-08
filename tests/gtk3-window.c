#include <gtk/gtk.h>
#include <stdio.h>

static GtkWidget *window;
static int status = 1;

static gboolean finish(gpointer unused) {
  gtk_main_quit();
  return FALSE;
}

static gboolean inspect(gpointer unused) {
  gchar *theme = NULL;
  g_object_get(gtk_settings_get_default(), "gtk-theme-name", &theme, NULL);
  // GTK falls back to Adwaita in silence when it does not find a theme.
  // The CSS of the named provider tells which one it loaded.
  gchar *named = gtk_css_provider_to_string(gtk_css_provider_get_named(theme, NULL));
  gchar *fallback = gtk_css_provider_to_string(gtk_css_provider_get_named("Adwaita", NULL));
  gboolean loaded = g_strcmp0(named, fallback) != 0;
  gboolean mapped = gtk_widget_get_mapped(window);
  const char *backend = G_OBJECT_TYPE_NAME(gdk_display_get_default());
  gint width = gtk_widget_get_allocated_width(window);
  gint height = gtk_widget_get_allocated_height(window);
  status = !(g_strcmp0(theme, "CrosAdapta") == 0 && loaded && mapped);
  g_print("GTK3 theme=%s loaded=%s mapped=%s size=%dx%d backend=%s\n",
      theme, loaded ? "yes" : "no", mapped ? "yes" : "no", width, height, backend);
  g_free(named);
  g_free(fallback);
  g_free(theme);
  if (status) {
    gtk_main_quit();
  } else {
    // Keep processing events while the host captures Weston's output.
    g_timeout_add_seconds(5, finish, NULL);
  }
  return FALSE;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  gtk_init(&argc, &argv);
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  // The probe names the variable that gave the display, for the capture.
  const char *label = g_getenv("GTK_PROBE_LABEL");
  if (!label) label = g_getenv("WAYLAND_DISPLAY");
  gchar *title = g_strdup_printf("Baguette GTK3 %s", label);
  gtk_window_set_title(GTK_WINDOW(window), title);
  g_free(title);
  gtk_window_set_default_size(GTK_WINDOW(window), 460, 260);
  gtk_container_set_border_width(GTK_CONTAINER(window), 16);
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_container_add(GTK_CONTAINER(window), box);
  gtk_box_pack_start(GTK_BOX(box), gtk_label_new("GTK3 in the shipped Baguette image"), FALSE, FALSE, 0);
  GtkWidget *entry = gtk_entry_new();
  gtk_entry_set_text(GTK_ENTRY(entry), "CrosAdapta from the host mount");
  gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 0);
  GtkWidget *check = gtk_check_button_new_with_label("GTK3 controls render correctly");
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(check), TRUE);
  gtk_box_pack_start(GTK_BOX(box), check, FALSE, FALSE, 0);
  GtkWidget *progress = gtk_progress_bar_new();
  gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(progress), 0.65);
  gtk_box_pack_start(GTK_BOX(box), progress, FALSE, FALSE, 0);
  GtkWidget *button = gtk_button_new_with_label("Test button");
  gtk_box_pack_start(GTK_BOX(box), button, FALSE, FALSE, 0);
  gtk_widget_show_all(window);
  g_timeout_add(1000, inspect, NULL);
  gtk_main();
  gtk_widget_destroy(window);
  gdk_display_sync(gdk_display_get_default());
  return status;
}
