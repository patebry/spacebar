import Foundation

/// The welcome sheet's "Try it" folder: a few files of different kinds in the support folder, made on demand. Files already
/// there are left as they are, so a user's edits to them survive another click.
enum SampleFolder {
    static let name = "Sample Folder"

    static var url: URL { SettingsFile.supportDir.appendingPathComponent(name, isDirectory: true) }

    static let files: [(String, String)] = [
        ("README.md", """
        # Welcome to spacebar

        You are looking at a **folder preview**. The sidebar lists everything in this folder; click a file, or use ↑ and ↓.

        - [ ] Click this line to edit it in place
        - [x] Tick a task: the file on disk changes too

        | Try | What you see |
        | --- | --- |
        | `data.csv` | a table you can sort |
        | `settings.json` | a tree you can fold |
        | `analysis.ipynb` | a notebook, cell by cell |
        | `hello.py` | highlighted code |

        > [!tip] Press Space on any folder in Finder
        > spacebar previews the folder with this sidebar, opening its README first.

        $$e^{i\\pi} + 1 = 0$$

        ```mermaid
        graph LR
          Finder -- Space --> spacebar --> Preview
        ```

        """),
        ("Notes/ideas.md", "# Ideas\n\n- Links between notes: [[README]]\n- #tags and callouts work too\n\n> [!note]\n> Folders nest in the sidebar.\n"),
        ("data.csv", "city;country;population;area km²\nTokyo;Japan;37400068;2194\nDelhi;India;28514000;1484\nShanghai;China;25582000;6341\n"
            + "São Paulo;Brazil;21650000;1521\nMexico City;Mexico;21581000;1485\nCairo;Egypt;20076000;3085\nMumbai;India;19980000;603\n"),
        ("settings.json", #"{"name": "sample", "version": 3, "features": {"tree": true, "raw": false, "levels": [1, 2, 3]}, "owner": null, "tags": ["json", "tree", "demo"]}"# + "\n"),
        ("hello.py", "from dataclasses import dataclass\n\n\n@dataclass\nclass Greeting:\n    name: str\n\n    def __str__(self) -> str:\n        return f\"Hello, {self.name}!\"\n\n\nprint(Greeting(\"spacebar\"))\n"),
        ("analysis.ipynb", #"""
        {"cells": [
          {"cell_type": "markdown", "metadata": {}, "source": ["# A small notebook\n", "Markdown cells render as Markdown."]},
          {"cell_type": "code", "execution_count": 1, "metadata": {}, "outputs": [{"name": "stdout", "output_type": "stream", "text": ["3 cities over 25 million\n"]}],
           "source": ["cities = {\"Tokyo\": 37.4, \"Delhi\": 28.5, \"Shanghai\": 25.6}\n", "print(f\"{len(cities)} cities over 25 million\")"]},
          {"cell_type": "code", "execution_count": 2, "metadata": {}, "outputs": [{"data": {"text/plain": ["37.4"]}, "execution_count": 2, "metadata": {}, "output_type": "execute_result"}],
           "source": ["max(cities.values())"]}
        ], "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python"}},
         "nbformat": 4, "nbformat_minor": 5}
        """#),
        ("todo.txt", "Press Space on this folder in Finder.\nOpen a file from the sidebar.\nChange the theme with the Aa button.\n"),
        ("logo.svg", ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="480" height="480"><rect width="120" height="120" rx="26" fill="#1f6feb"/><rect x="24" y="74" width="72" height="14" rx="7" fill="#fff"/></svg>"## + "\n"),
    ]

    /// Creates the folder and whichever sample files are missing. Returns the folder, or the error that stopped it.
    static func create(in dir: URL = url) -> Result<URL, Error> {
        let fm = FileManager.default
        do {
            for (rel, text) in files {
                let file = dir.appendingPathComponent(rel)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                var st = stat()
                if lstat(file.path, &st) == 0 { continue }
                try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            }
            return .success(dir)
        } catch {
            return .failure(error)
        }
    }
}
