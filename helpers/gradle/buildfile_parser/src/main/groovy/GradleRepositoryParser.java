import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

import org.apache.commons.io.IOUtils;
import org.codehaus.groovy.ast.ASTNode;
import org.codehaus.groovy.ast.GroovyCodeVisitor;
import org.codehaus.groovy.ast.builder.AstBuilder;
import org.codehaus.groovy.ast.InnerClassNode;
import org.codehaus.groovy.control.MultipleCompilationErrorsException;


public class GradleRepositoryParser
{

    private List<ASTNode> nodes;
    private File file;

    public GradleRepositoryParser( File inputfile ) throws MultipleCompilationErrorsException, IOException
    {
        this( IOUtils.toString( new FileInputStream( inputfile ), "UTF-8" ) );
        this.file = inputfile;
    }

    public GradleRepositoryParser( String scriptContents ) throws MultipleCompilationErrorsException
    {
        AstBuilder builder = new AstBuilder();
        nodes = builder.buildFromString( scriptContents );
    }

    public List<GradleRepository> getAllRepositories()
    {
        FindRepositoriesVisitor visitor = new FindRepositoriesVisitor();
        walkScript( visitor );

        return visitor.getRepositories();
    }

    public void walkScript( GroovyCodeVisitor visitor )
    {
        for( ASTNode node : nodes )
        {
            if ( node instanceof InnerClassNode )
            {
                continue;
            }
            node.visit( visitor );
        }
    }

}
