/* Make mermaid diagrams follow the Material dark/light toggle */
document$.subscribe(function () {
  var scheme = document.body.getAttribute("data-md-color-scheme") || "slate";
  var isDark = scheme !== "default";
  mermaid.initialize({
    startOnLoad: false,
    theme: isDark ? "dark" : "default",
    themeVariables: isDark ? {
      primaryColor: "#7c3aed",
      primaryTextColor: "#e9d5ff",
      primaryBorderColor: "#a78bfa",
      lineColor: "#a78bfa",
      secondaryColor: "#1e1b4b",
      tertiaryColor: "#2d1b69",
      background: "#1a1a2e",
      nodeBorder: "#7c3aed",
      clusterBkg: "#1e1b4b",
      titleColor: "#e9d5ff",
      edgeLabelBackground: "#2d1b69",
      fontFamily: "Inter, sans-serif"
    } : {
      primaryColor: "#7c3aed",
      primaryTextColor: "#fff",
      primaryBorderColor: "#6d28d9",
      lineColor: "#6d28d9",
      fontFamily: "Inter, sans-serif"
    }
  });
  mermaid.run();
});
