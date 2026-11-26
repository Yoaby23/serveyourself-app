export async function reportProductionHealth(github, context, exercise = false) {
    const repository = context.repo;
    const title = exercise ? 'ServeYourself: prueba de alerta operativa' : 'ServeYourself: falla en la comprobación de producción';
    const run = `https://github.com/${repository.owner}/${repository.repo}/actions/runs/${context.runId}`;
    const body = exercise
        ? `Prueba de entrega de la alerta. Confirma con el responsable del turno que recibió el aviso y cierra esta incidencia.\n\nEjecución: ${run}`
        : `La comprobación pública falló. Revisa la ejecución para identificar el paso afectado y cierra la incidencia cuando el servicio vuelva a responder.\n\nEjecución: ${run}`;
    const issues = await github.paginate(github.rest.issues.listForRepo, { ...repository, state: 'open', creator: 'github-actions[bot]', per_page: 100 });
    const previous = issues.find(issue => !issue.pull_request && issue.title === title);
    if (previous) {
        await github.rest.issues.update({ ...repository, issue_number: previous.number, body, assignees: [repository.owner] });
    } else {
        await github.rest.issues.create({ ...repository, title, body, assignees: [repository.owner] });
    }
}
