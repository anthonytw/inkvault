import "./style.css";
import { App } from "./ui/app.ts";

const root = document.getElementById("app");
if (root) new App(root).start();
